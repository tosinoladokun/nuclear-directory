require "csv"

# Reads who owns each nuclear generator from EIA's annual Form EIA-860 zip
# (#382), the same zip EiaPlants reads. Two workbooks in it say it:
# - "3_1_Generator_Y2025.xlsx" lists every generator with an Ownership code.
#   S: the utility that reports it owns it alone. J (jointly owned) and W
#   (wholly owned by another company): its owners are in Schedule 4.
# - "4___Owner_Y2025.xlsx" (Schedule 4, "Jointly or Third-Party Owned Only")
#   lists those owners, each with EIA's utility ID and its share.
# So a generator's owners are the reporting utility at 100% for S, else its
# Schedule 4 rows. Only nuclear generators, operable or proposed, are kept,
# one row per generator and owner, as CSV (to_csv), sorted so each owner's
# rows at a plant sit together and can be quoted as one passage.
class DataQuality::Plugins::EiaOwners::OwnerFile
  PlantFile = DataQuality::Plugins::EiaPlants::PlantFile
  Workbook = PlantFile::Workbook
  Unreadable = Workbook::Unreadable

  OWNER_ENTRY = %r{(?:\A|/)4_+Owner_Y(\d{4})\.xlsx\z}i
  OWNER_SHEET = "Ownership"
  SOLE = "S"
  GENERATOR_COLUMNS = [ "Utility ID", "Utility Name", "Plant Code", "Plant Name", "State", "Generator ID", "Technology",
    "Ownership", "Nameplate Capacity (MW)" ].freeze
  OWNER_COLUMNS = [ "Plant Code", "Generator ID", "Owner Name", "Ownership ID", "Percent Owned" ].freeze
  # Our name => what it holds. percent_owned is blank for a sole owner
  # (Ownership S): EIA states no share for it, because it owns it all.
  COLUMNS = {
    "eia_plant_id" => "Plant Code",
    "plant_name" => "Plant Name",
    "state" => "State",
    "generator_id" => "Generator ID",
    "nameplate_mw" => "Nameplate Capacity (MW)",
    "ownership" => "Ownership",
    "owner_eia_utility_id" => "Owner's EIA utility ID",
    "owner_name" => "Owner Name",
    "percent_owned" => "Percent Owned"
  }.freeze

  # One hash per nuclear generator and owner, keyed by COLUMNS' names.
  # Raises Unreadable when the zip, a workbook, a sheet or a column is
  # missing, or the file lists no nuclear generator.
  def self.rows(bytes)
    PlantFile.with_workbooks(bytes, generator: PlantFile::GENERATOR_ENTRY, owner: OWNER_ENTRY) do |paths|
      generators = nuclear_generators(paths[:generator])
      owners = owners_of(paths[:owner], generators.to_set { |g| g.values_at("eia_plant_id", "generator_id") })
      generators.flat_map do |generator|
        base = generator.except("utility_id", "utility_name")
        if generator["ownership"] == SOLE
          [ base.merge("owner_eia_utility_id" => generator["utility_id"], "owner_name" => generator["utility_name"], "percent_owned" => nil) ]
        else
          # A J or W generator with no Schedule 4 rows: an incomplete file, so
          # the last good snapshot stays rather than a partial ownership.
          owners.fetch(generator.values_at("eia_plant_id", "generator_id")) do
            raise Unreadable, "Schedule 4 lists no owners for #{generator['plant_name']} generator #{generator['generator_id']} " \
              "(ownership #{generator['ownership']})"
          end.map { |owner| base.merge(owner) }
        end
      end.sort_by { |row| [ row["eia_plant_id"].to_i, row["owner_eia_utility_id"].to_i, row["generator_id"] ] }
    end
  end

  def self.to_csv(rows)
    CSV.generate { |csv| csv << COLUMNS.keys; rows.each { |row| csv << row.values_at(*COLUMNS.keys) } }
  end

  # Nuclear generators on the generator workbook's operable and proposed
  # sheets, with the reporting utility and the ownership code.
  def self.nuclear_generators(path)
    generators = []
    PlantFile::GENERATOR_SHEETS.each do |sheet|
      workbook = Workbook.new(path, sheet:)
      workbook.each_record(marker: "Plant Code", titles: GENERATOR_COLUMNS) do |cells|
        next unless cells["Technology"].to_s.strip == PlantFile::NUCLEAR

        value = ->(title) { cells[title].to_s.strip.presence }
        generators << { "utility_id" => value.("Utility ID"), "utility_name" => value.("Utility Name"),
          "eia_plant_id" => value.("Plant Code"), "plant_name" => value.("Plant Name"), "state" => value.("State"),
          "generator_id" => value.("Generator ID"), "nameplate_mw" => number(value.("Nameplate Capacity (MW)"), 1),
          "ownership" => value.("Ownership") }
      end
    ensure
      workbook&.close
    end
    raise Unreadable, "No nuclear generators in the generator workbook" if generators.empty?

    generators
  end

  # Schedule 4's owners of these generators: { [plant, generator] => [owner, …] }.
  def self.owners_of(path, generators)
    owners = Hash.new { |hash, key| hash[key] = [] }
    workbook = Workbook.new(path, sheet: OWNER_SHEET)
    workbook.each_record(marker: "Plant Code", titles: OWNER_COLUMNS) do |cells|
      value = ->(title) { cells[title].to_s.strip.presence }
      key = [ value.("Plant Code"), value.("Generator ID") ]
      next unless generators.include?(key)

      owners[key] << { "owner_eia_utility_id" => value.("Ownership ID"), "owner_name" => value.("Owner Name"),
        "percent_owned" => number(value.("Percent Owned"), 6) }
    end
    owners
  ensure
    workbook&.close
  end

  # EIA's numbers as written, without the float noise of the workbook's
  # storage ("0.57410000000000005" is "0.5741"). nil when blank.
  # A blank stays blank; anything else that isn't a number ("N/A") makes the
  # file unreadable, so the last good copy is kept.
  def self.number(text, places)
    return if text.to_s.strip.empty?

    value = BigDecimal(text.to_s.strip, exception: false) or raise Unreadable, "#{text.inspect} isn't a number"
    value.round(places).to_s("F").sub(/\.0\z/, "")
  end
  private_class_method :nuclear_generators, :owners_of, :number
end
