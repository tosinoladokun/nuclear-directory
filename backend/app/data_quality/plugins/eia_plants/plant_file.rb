require "csv"

# Reads the Plant sheet of EIA's annual Form EIA-860 release (#319): the
# yearly zip holds one workbook per schedule, and "2___Plant_Y2025.xlsx" has
# one row per plant with its address. The zip is about 24 MB; each workbook
# inside it is copied to a temp file through the same bounded inflater as
# the 860M reader, then streamed like it.
#
# Only nuclear plants' rows are stored, as CSV (to_csv), so each candidate
# quotes its row verbatim from the source's content_text. Which plants are
# nuclear comes from the same zip's generator workbook ("3_1_Generator_Y2025
# .xlsx": any generator whose Technology is Nuclear, operable or proposed),
# so what's stored depends on the file alone: a site added to the directory
# later still finds its row when the file is answered "not modified".
class DataQuality::Plugins::EiaPlants::PlantFile
  Workbook = DataQuality::Plugins::EiaGenerators::Workbook
  Unreadable = Workbook::Unreadable

  SHEET = "Plant"
  ENTRY = %r{(?:\A|/)2_+Plant_Y(\d{4})\.xlsx\z}i
  GENERATOR_ENTRY = %r{(?:\A|/)3_1_+Generator_Y(\d{4})\.xlsx\z}i
  # Operating plants, and ones being built or licensed (Kemmerer).
  GENERATOR_SHEETS = %w[Operable Proposed].freeze
  NUCLEAR = "Nuclear"
  # Our name => EIA's column header.
  COLUMNS = {
    "eia_plant_id" => "Plant Code",
    "plant_name" => "Plant Name",
    "street_address" => "Street Address",
    "city" => "City",
    "state" => "State",
    "zip" => "Zip",
    "county" => "County"
  }.freeze

  # The rows of the zip's plant workbook for plants with a nuclear
  # generator, as hashes keyed by COLUMNS' names. Raises Unreadable when the
  # zip, a workbook, a sheet or a column is missing, a row has no plant
  # code, or the file lists no nuclear generator.
  def self.plants(bytes)
    with_workbooks(bytes, plant: ENTRY, generator: GENERATOR_ENTRY) do |paths|
      nuclear = nuclear_plant_codes(paths[:generator])
      read(paths[:plant], keep: ->(plant) { nuclear.include?(plant["eia_plant_id"]) })
    end
  end

  def self.to_csv(plants)
    CSV.generate { |csv| csv << COLUMNS.keys; plants.each { |plant| csv << plant.values_at(*COLUMNS.keys) } }
  end

  # Copies each named workbook out of the yearly zip to a temp file and
  # yields { name => path }. entries: { name => the entry's file name pattern }.
  def self.with_workbooks(bytes, entries)
    Tempfile.create([ "eia860", ".zip" ], binmode: true) do |zip_file|
      zip_file.write(bytes)
      zip_file.flush
      files = entries.to_h { |name, _| [ name, Tempfile.create([ "eia860_#{name}", ".xlsx" ], binmode: true) ] }
      begin
        entries.each { |name, pattern| copy_workbook(zip_file.path, pattern, files[name]) }
        yield files.transform_values(&:path)
      ensure
        files.each_value { |file| file.close; File.unlink(file.path) if File.exist?(file.path) }
      end
    end
  rescue Nokogiri::XML::SyntaxError, Zip::Error, Zlib::Error => error
    raise Unreadable, "The EIA-860 file is damaged: #{error.class}: #{error.message}"
  end

  # Plant codes with a nuclear generator on the generator workbook's
  # operable or proposed sheet.
  def self.nuclear_plant_codes(path)
    codes = Set.new
    GENERATOR_SHEETS.each do |sheet|
      workbook = Workbook.new(path, sheet:)
      workbook.each_record(marker: "Plant Code", titles: [ "Plant Code", "Technology" ]) do |cells|
        codes << cells["Plant Code"].strip if cells["Technology"].to_s.strip == NUCLEAR && cells["Plant Code"].present?
      end
    ensure
      workbook&.close
    end
    raise Unreadable, "No nuclear generators in the generator workbook" if codes.empty?

    codes
  end

  def self.copy_workbook(zip_path, pattern, out)
    Zip::File.open(zip_path) do |zip|
      entry = zip.entries.find { |e| e.name.match?(pattern) } or raise Unreadable, "No #{workbook_label(pattern)} in the zip"
      File.open(zip_path, "rb") do |file|
        stream = Workbook::Inflating.new(file, entry)
        while (chunk = stream.read(Workbook::Inflating::CHUNK))
          out.write(chunk)
        end
      end
      out.flush
    end
  rescue Zip::Error => error
    raise Unreadable, "Not a readable zip: #{error.message}"
  end

  def self.workbook_label(pattern)
    { ENTRY => "plant workbook (2___Plant_Y….xlsx)", GENERATOR_ENTRY => "generator workbook (3_1_Generator_Y….xlsx)" }
      .fetch(pattern) { "workbook matching #{pattern.source}" }
  end

  def self.read(path, keep:)
    workbook = Workbook.new(path, sheet: SHEET)
    plants = []
    workbook.each_record(marker: COLUMNS["eia_plant_id"], titles: COLUMNS.values) do |cells|
      plant = COLUMNS.transform_values { |title| cells[title]&.strip.presence }
      next if plant.values.all?(&:nil?) # a blank row at the end of the sheet
      raise Unreadable, "A plant row has no #{COLUMNS['eia_plant_id']} (#{plant['plant_name'] || 'unnamed'})" unless plant["eia_plant_id"]

      plants << plant if keep.call(plant)
    end
    plants
  ensure
    workbook&.close
  end
  private_class_method :copy_workbook, :workbook_label, :read
end
