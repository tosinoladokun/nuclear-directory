require "csv"

# Reads the Plant sheet of EIA's annual Form EIA-860 release (#319): the
# yearly zip holds one workbook per schedule, and "2___Plant_Y2025.xlsx" has
# one row per plant with its address. The zip is about 24 MB; the plant
# workbook inside it is copied to a temp file through the same bounded
# inflater as the 860M reader, then streamed like it.
#
# Only the rows keep says matter are stored, as CSV (to_csv), so each
# candidate quotes its row verbatim from the source's content_text.
class DataQuality::Plugins::EiaPlants::PlantFile
  Workbook = DataQuality::Plugins::EiaGenerators::Workbook
  Unreadable = Workbook::Unreadable

  SHEET = "Plant"
  ENTRY = %r{(?:\A|/)2_+Plant_Y(\d{4})\.xlsx\z}i
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

  # The plant rows of the zip's plant workbook for which keep is true, as
  # hashes keyed by COLUMNS' names. Raises Unreadable when the zip, the
  # workbook, its sheet or a column is missing, or a row has no plant code.
  def self.plants(bytes, keep:)
    Tempfile.create([ "eia860", ".zip" ], binmode: true) do |zip_file|
      zip_file.write(bytes)
      zip_file.flush
      Tempfile.create([ "eia860_plant", ".xlsx" ], binmode: true) do |xlsx|
        copy_plant_workbook(zip_file.path, xlsx)
        read(xlsx.path, keep:)
      end
    end
  rescue Nokogiri::XML::SyntaxError, Zip::Error, Zlib::Error => error
    raise Unreadable, "The EIA-860 file is damaged: #{error.class}: #{error.message}"
  end

  def self.to_csv(plants)
    CSV.generate { |csv| csv << COLUMNS.keys; plants.each { |plant| csv << plant.values_at(*COLUMNS.keys) } }
  end

  def self.copy_plant_workbook(zip_path, out)
    Zip::File.open(zip_path) do |zip|
      entry = zip.entries.find { |e| e.name.match?(ENTRY) } or raise Unreadable, "No plant workbook (2___Plant_Y….xlsx) in the zip"
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
  private_class_method :copy_plant_workbook, :read
end
