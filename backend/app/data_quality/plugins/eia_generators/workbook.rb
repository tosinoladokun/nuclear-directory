require "csv"

# Reads the nuclear generators from EIA's monthly generator inventory
# (Form EIA-860M, an .xlsx). Only the "Operating" sheet, only rows whose
# Technology is "Nuclear". The sheet has ~28,000 rows (a 56 MB XML file), so
# it's streamed rather than loaded whole, and it runs inside the web service's
# 512 MB (#188): the file is read from a temp file rather than memory, and the
# sheet and shared strings are walked node by node, with no document built for
# any of it.
#
# The rows that matter are stored as CSV (to_csv), so each candidate can quote
# its row verbatim from the source's content_text.
class DataQuality::Plugins::EiaGenerators::Workbook
  class Unreadable < StandardError; end

  SHEET = "Operating"
  # Our name => EIA's column header.
  COLUMNS = {
    "eia_plant_id" => "Plant ID",
    "plant_name" => "Plant Name",
    "generator_id" => "Generator ID",
    "state" => "Plant State",
    "county" => "County",
    "net_summer_capacity_mw" => "Net Summer Capacity (MW)",
    "nameplate_capacity_mw" => "Nameplate Capacity (MW)",
    "status" => "Status",
    "latitude" => "Latitude",
    "longitude" => "Longitude",
    "entity_name" => "Entity Name"
  }.freeze
  TECHNOLOGY = "Technology"
  NUCLEAR = "Nuclear"
  # Columns that must be a plain number when present. Anything else (say
  # "N/A") means the layout changed, and is reported rather than read as 0.
  NUMERIC = %w[net_summer_capacity_mw nameplate_capacity_mw latitude longitude].freeze
  NUMBER = /\A-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?\z/
  # What identifies a generator. A nuclear row without one of these can't be
  # matched to its unit, so it means the data changed: reported, not skipped.
  IDENTITY = %w[eia_plant_id plant_name state generator_id].freeze
  # workbook.xml and its relationships are a few KB; they're read whole.
  SMALL_PART = 5.megabytes

  # Returns an array of hashes keyed by COLUMNS' names. Raises Unreadable
  # when the file isn't a workbook, the sheet or a column is missing, a
  # number column holds something that isn't a number, or no nuclear rows
  # are found (EIA may have changed the layout).
  def self.nuclear_generators(bytes)
    Tempfile.create([ "eia860m", ".xlsx" ], binmode: true) do |file|
      file.write(bytes)
      file.flush
      workbook = new(file.path)
      begin
        workbook.nuclear_generators
      ensure
        workbook.close
      end
    end
  rescue Nokogiri::XML::SyntaxError, Zip::Error, Zlib::Error => error
    # A damaged sheet or archive is reported like any other unreadable file.
    raise Unreadable, "The workbook is damaged: #{error.class}: #{error.message}"
  end

  def self.to_csv(generators)
    CSV.generate { |csv| csv << COLUMNS.keys; generators.each { |g| csv << g.values_at(*COLUMNS.keys) } }
  end

  # sheet: the sheet to read (EIA-860's Plant file has a "Plant" sheet).
  def initialize(path, sheet: SHEET)
    @path = path
    @sheet = sheet
    @zip = Zip::File.open(path)
  rescue Zip::Error => error
    raise Unreadable, "Not a readable .xlsx: #{error.message}"
  end

  def close = @zip&.close

  def nuclear_generators
    generators = []
    each_record(marker: COLUMNS["eia_plant_id"], titles: COLUMNS.values + [ TECHNOLOGY ]) do |cells|
      next unless cells[TECHNOLOGY].to_s.strip == NUCLEAR

      generators << COLUMNS.transform_values { |title| cells[title]&.strip.presence }
        .tap { |row| check_identity!(row) && check_numbers!(row) }
    end
    raise Unreadable, "No nuclear generators on the #{@sheet} sheet" if generators.empty?

    generators
  end

  # Yields each row under the header as { column title => text }. Title rows
  # come first; the header is the first row with marker in it ("Plant ID").
  # Raises Unreadable when there's no header, or one of titles is missing
  # from it.
  def each_record(marker:, titles:)
    header = nil
    each_row(sheet_path) do |cells|
      if header.nil?
        header = cells.invert if cells.value?(marker)
        next
      end
      yield header.transform_values { |column| cells[column] }
    end

    raise Unreadable, "No header row with #{marker.inspect} on the #{@sheet} sheet" unless header
    missing = titles - header.keys
    raise Unreadable, "Columns missing from the #{@sheet} sheet: #{missing.join(', ')}" if missing.any?
  end

  # Namespaces are dropped throughout: a row read from the stream on its
  # own doesn't carry the sheet's namespace declarations.
  private
    def check_identity!(row)
      missing = IDENTITY.select { |column| row[column].nil? }
      return true if missing.empty?

      raise Unreadable, "A nuclear row has no #{missing.map { |column| COLUMNS[column] }.join(', ')} " \
        "(plant #{row['eia_plant_id'] || row['plant_name'] || 'unknown'})"
    end

    def check_numbers!(row)
      NUMERIC.each do |column|
        value = row[column]
        next if value.nil? || value.match?(NUMBER)

        raise Unreadable, "#{COLUMNS[column]} is #{value.inspect} for #{row['plant_name']} #{row['generator_id']}, not a number"
      end
    end

    def sheet_path
      sheet = xml("xl/workbook.xml").at_xpath("//sheet[@name='#{@sheet}']") or raise Unreadable, "No #{@sheet.inspect} sheet"
      target = xml("xl/_rels/workbook.xml.rels").at_xpath("//Relationship[@Id='#{sheet['id']}']")&.[]("Target")
      raise Unreadable, "Can't find the #{@sheet} sheet's file" unless target

      target.start_with?("/") ? target.delete_prefix("/") : "xl/#{target}"
    end

    # Yields each row as { "A" => "Plant ID", "B" => … }, walking the sheet's
    # XML node by node: a cell's text is gathered from its <v> (a value, or
    # an index into the shared strings) or its inline <t> runs.
    def each_row(path)
      shared_strings
      row = column = type = text = nil
      stream(path) do |node, name, start|
        case name
        when "row"
          if start
            row = {}
            yield row if node.empty_element?
          else
            yield row
          end
        when "c"
          if start
            column = node.attribute("r").to_s[/\A[A-Z]+/]
            type = node.attribute("t")
            text = nil
            row[column] = nil if node.empty_element?
          else
            row[column] = cell_value(type, text)
          end
        when "v", "t"
          text = +"" if start && text.nil?
        when :text
          text << node.value if text
        end
      end
    end

    def cell_value(type, text)
      return if text.nil?

      type == "s" ? shared_strings[text.to_i] : text
    end

    # Every <si>'s text runs joined, in order, streamed like the sheet.
    def shared_strings
      @shared_strings ||= begin
        strings = []
        if @zip.find_entry("xl/sharedStrings.xml")
          current = nil
          stream("xl/sharedStrings.xml") do |node, name, start|
            case name
            when "si"
              if start
                current = +""
                strings << current if node.empty_element?
              else
                strings << current
              end
            when :text
              current << node.value if current
            end
          end
        end
        strings
      end
    end

    # Yields (node, local name, start?) for each element start and end, and
    # (node, :text, nil) for text inside <v> or <t>. Namespaces are ignored.
    def stream(path)
      entry = @zip.find_entry(path) or raise Unreadable, "Missing #{path}"
      in_text = false
      File.open(@path, "rb") do |file|
        Nokogiri::XML::Reader(Inflating.new(file, entry)).each do |node|
          case node.node_type
          when Nokogiri::XML::Reader::TYPE_ELEMENT
            in_text = %w[v t].include?(node.local_name) && !node.empty_element?
            yield node, node.local_name, true
          when Nokogiri::XML::Reader::TYPE_END_ELEMENT
            in_text = false
            yield node, node.local_name, false
          when Nokogiri::XML::Reader::TYPE_TEXT, Nokogiri::XML::Reader::TYPE_CDATA,
               Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE
            yield node, :text, nil if in_text
          end
        end
      end
    end

    # One zip entry as an IO the XML reader pulls from, inflated a chunk at a
    # time. rubyzip's own entry stream ends up holding the whole inflated
    # sheet (about 60 MB for the 860M's Operating sheet), which is what this
    # avoids.
    class Inflating
      # Compressed bytes fed to Zlib per step: deflate expands at most about
      # 1,000 to 1, so one step yields at most about 16 MB.
      CHUNK = 16 * 1024
      LOCAL_HEADER = 30
      # The most one part may expand to. The 860M's Operating sheet is about
      # 56 MB; a part claiming or reaching more is refused, so a crafted file
      # can't fill the 512 MB instance before the checksum is checked.
      MAX_SIZE = 200.megabytes

      def initialize(file, entry)
        raise Unreadable, "#{entry.name} is too large to read (#{entry.size} bytes)" if entry.size > MAX_SIZE

        @file = file
        @entry = entry
        @left = entry.compressed_size
        # Checked against the entry at the end, as rubyzip does, so a damaged
        # file is reported rather than read as different rows.
        @crc = Zlib.crc32
        @size = 0
        @inflater = entry.compression_method == Zip::Entry::DEFLATED ? Zlib::Inflate.new(-Zlib::MAX_WBITS) : nil
        @pending = +"".b
        # The data starts after the entry's local header, whose name and
        # extra field lengths can differ from the central directory's.
        file.seek(entry.local_header_offset)
        header = file.read(LOCAL_HEADER)
        unless header&.bytesize == LOCAL_HEADER && header.start_with?("PK\x03\x04".b)
          raise Unreadable, "#{entry.name}: bad local header"
        end

        name_length, extra_length = header.unpack("@26vv")
        file.seek(entry.local_header_offset + LOCAL_HEADER + name_length + extra_length)
      end

      def read(length = nil, buffer = nil)
        fill(length)
        return nil if @pending.empty? && length&.positive?

        out = length ? @pending.byteslice(0, length) : @pending
        @pending = length ? (@pending.byteslice(length..) || +"".b) : +"".b
        buffer ? buffer.replace(out) : out
      end

      private
        def fill(length)
          while (length.nil? || @pending.bytesize < length) && @left.positive?
            chunk = @file.read([ @left, CHUNK ].min) or raise Unreadable, "#{@entry.name}: the file ends early"
            @left -= chunk.bytesize
            emit(@inflater ? @inflater.inflate(chunk) : chunk)
            finish if @left.zero?
          end
        end

        def emit(data)
          @crc = Zlib.crc32(data, @crc)
          @size += data.bytesize
          raise Unreadable, "#{@entry.name} expands past #{MAX_SIZE / 1.megabyte} MB" if @size > MAX_SIZE

          @pending << data
        end

        def finish
          emit(@inflater.finish) if @inflater && !@inflater.finished?
          return if @crc == @entry.crc && @size == @entry.size

          raise Unreadable, "#{@entry.name} is damaged: its checksum or size doesn't match the zip's record"
        end
    end

    def xml(path) = Nokogiri::XML(read(path)).remove_namespaces!

    # The workbook's small parts (workbook.xml and its relationships), read
    # whole through the same bounded inflater.
    def read(path)
      entry = @zip.find_entry(path) or raise Unreadable, "Missing #{path}"
      raise Unreadable, "#{path} is too large for a workbook index (#{entry.size} bytes)" if entry.size > SMALL_PART

      File.open(@path, "rb") { |file| Inflating.new(file, entry).read }
    end
end
