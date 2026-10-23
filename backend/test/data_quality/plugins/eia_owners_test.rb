require "test_helper"
require_relative "../support/dummy_plugin"

# Who owns each nuclear plant, from EIA-860 (#382): the generator file's
# ownership code and Schedule 4. The zip is built here like EIA's 2025 file
# (checked against the real one, 19 Oct 2026): a title row, the header, one
# row per generator or owner. Vogtle, Calvert Cliffs, Catawba and Kemmerer
# are their real rows, cut to these columns; V. C. Summer's second share is
# changed so its shares don't add up.
class DataQuality::Plugins::EiaOwnersTest < ActiveSupport::TestCase
  include ReviewHelpers
  Plugin = DataQuality::Plugins::EiaOwners
  FILE = "https://www.eia.gov/electricity/data/eia860/xls/eia8602025.zip"
  SOURCE = "#{FILE}#owners".freeze
  GENERATOR_HEADER = [ "Utility ID", "Utility Name", "Plant Code", "Plant Name", "State", "Generator ID", "Technology", "Ownership",
    "Nameplate Capacity (MW)" ].freeze
  OPERABLE = [
    [ "7140", "Georgia Power Co", "649", "Vogtle", "GA", "1", "Nuclear", "J", "1150" ],
    [ "7140", "Georgia Power Co", "649", "Vogtle", "GA", "2", "Nuclear", "J", "1150" ],
    [ "55951", "Constellation Nuclear", "6011", "Calvert Cliffs Nuclear Power Plant", "MD", "1", "Nuclear", "S", "918" ],
    [ "5416", "Duke Energy Carolinas, LLC", "6036", "Catawba", "SC", "1", "Nuclear", "J", "1205.0999999999999" ],
    [ "5416", "Duke Energy Carolinas, LLC", "6036", "Catawba", "SC", "2", "Nuclear", "J", "1205.0999999999999" ],
    [ "17539", "Dominion Energy South Carolina, Inc", "6127", "V C Summer", "SC", "1", "Nuclear", "J", "1029.5999999999999" ],
    [ "195", "Alabama Power Co", "3", "Barry", "AL", "1", "Conventional Steam Coal", "S", "153.1" ]
  ].freeze
  PROPOSED = [ [ "67013", "US SFR Owner LLC", "68635", "Kemmerer Unit 1", "WY", "KU1", "Nuclear", "S", "500" ] ].freeze
  OWNER_HEADER = [ "Utility ID", "Utility Name", "Plant Code", "Plant Name", "State", "Generator ID", "Status", "Owner Name",
    "Owner Street Address", "Owner City", "Owner State", "Owner Zip", "Ownership ID", "Percent Owned" ].freeze
  owner = ->(plant, name, generator, owner_name, owner_id, pct) { [ "1", "Utility", plant, name, "XX", generator, "OP", owner_name, "", "", "", "", owner_id, pct ] }
  OWNERS = [
    *%w[1 2].flat_map do |generator|
      [ owner.("649", "Vogtle", generator, "Georgia Power Co", "7140", "0.45700000000000002"),
        owner.("649", "Vogtle", generator, "Oglethorpe Power Corporation", "13994", "0.3"),
        owner.("649", "Vogtle", generator, "Municipal Electric Authority - (GA)", "13100", "0.22700000000000001"),
        owner.("649", "Vogtle", generator, "Dalton Utilities", "4744", "1.6E-2") ]
    end,
    owner.("6036", "Catawba", "1", "North Carolina Mun Power Agny #1", "13630", "0.75"),
    owner.("6036", "Catawba", "1", "Piedmont Municipal Power Agny", "15028", "0.25"),
    owner.("6036", "Catawba", "2", "Duke Energy Carolinas, LLC", "5416", "0.38490000000000002"),
    owner.("6036", "Catawba", "2", "North Carolina El Member Corp", "13683", "0.61509999999999998"),
    owner.("6127", "V C Summer", "1", "Dominion Energy South Carolina, Inc", "17539", "0.66669999999999996"),
    owner.("6127", "V C Summer", "1", "South Carolina Public Service Authority", "17543", "0.3"),
    owner.("3", "Barry", "1", "Alabama Power Co", "195", "1")
  ].freeze

  # An .xlsx with these sheets: { name => [title, header, *rows] }.
  def workbook(sheets)
    cell = ->(col, r, text) { %(<c r="#{col}#{r}" t="inlineStr"><is><t>#{text.encode(xml: :text)}</t></is></c>) }
    row = ->(r, values) { %(<row r="#{r}">#{values.each_with_index.map { |v, i| cell.(("A".."Z").to_a[i], r, v) unless v.to_s.empty? }.join}</row>) }
    ns = %(xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("xl/workbook.xml")
      zip.write(%(<workbook #{ns} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>) +
        sheets.keys.each_with_index.map { |name, i| %(<sheet name="#{name}" sheetId="#{i + 1}" r:id="rId#{i + 1}"/>) }.join + "</sheets></workbook>")
      zip.put_next_entry("xl/_rels/workbook.xml.rels")
      zip.write(%(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) +
        sheets.keys.each_index.map { |i| %(<Relationship Id="rId#{i + 1}" Target="worksheets/sheet#{i + 1}.xml"/>) }.join + "</Relationships>")
      sheets.values.each_with_index do |rows, i|
        zip.put_next_entry("xl/worksheets/sheet#{i + 1}.xml")
        zip.write(%(<worksheet #{ns}><sheetData>#{rows.each_with_index.map { |values, r| row.(r + 1, values) }.join}</sheetData></worksheet>))
      end
    end.string
  end

  def yearly_zip(owners: OWNERS, owner_workbook: true)
    generators = workbook("Operable" => [ [ "Schedule 3 (Operable)" ], GENERATOR_HEADER, *OPERABLE ],
      "Proposed" => [ [ "Schedule 3 (Proposed)" ], GENERATOR_HEADER, *PROPOSED ])
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("3_1_Generator_Y2025.xlsx")
      zip.write(generators)
      if owner_workbook
        zip.put_next_entry("4___Owner_Y2025.xlsx")
        zip.write(workbook("Ownership" => [ [ "2025 Form EIA-860 Data - Schedule 4, 'Generator Ownership'" ], OWNER_HEADER, *owners ]))
      end
    end.string
  end

  setup do
    stub_request(:get, "https://www.eia.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /private/\n")
    stub_request(:get, DataQuality::Plugins::EiaPlants::INDEX_URL).to_return(body: %(<a href="xls/eia8602025.zip">2025</a>))
    @file = stub_request(:get, FILE).to_return(body: yearly_zip)
    by = { verification_status: "verified", verified_by: "human:tosin" }
    @vogtle = Facility.create!(name: "Plant Vogtle", eia_plant_id: "649", state: "GA", facility_type: "power_reactor", **by)
    @calvert = Facility.create!(name: "Calvert Cliffs", eia_plant_id: "6011", state: "MD", facility_type: "power_reactor", **by)
    catawba = Facility.create!(name: "Catawba Nuclear Station", eia_plant_id: "6036", state: "SC", facility_type: "power_reactor", **by)
    @catawba1 = Facility.create!(name: "Catawba 1", nrc_docket: "05000413", parent: catawba, **by)
    @catawba2 = Facility.create!(name: "Catawba 2", nrc_docket: "05000414", parent: catawba, **by)
    Facility.create!(name: "V. C. Summer", eia_plant_id: "6127", state: "SC", facility_type: "power_reactor", **by)
    # Georgia Power already owns Vogtle on the site, with a person's decision.
    @georgia_power = Organization.create!(name: "Georgia Power", **by).tap { |org| org.aliases.create!(alias: "Georgia Power") }
    FacilityRelationship.create!(organization: @georgia_power, facility: @vogtle, relationship_type: "owns", ownership_pct: 45.7, **by)
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl! = plugin.crawl(CrawlRun.create!(stage: "crawl", source_kind: "eia_owners"))
  def source = Source.find_by!(url: SOURCE)
  def stored = CSV.parse(source.content_text, headers: true).map(&:to_h)
  def links = plugin.extract(source, nil).select { |c| c[:kind] == "facility_relationship" }

  def run!(verifier: PublishEverything.new)
    DataQuality::Pipeline.run("eia_owners", plugin:, only: %w[crawl extract match verify], verifier:)
  end

  def claim(owner, facility)
    Candidate.where(kind: "facility_relationship").find do |c|
      c.payload.dig("organization", "eia_utility_id") == owner && c.payload["facility"].values_at("eia_plant_id", "name").include?(facility)
    end
  end

  test "is the plug-in for eia_owners" do
    assert_instance_of Plugin, DataQuality::Plugin.for("eia_owners")
  end

  test "keeps each nuclear generator's owners: the reporting utility for a sole owner, else Schedule 4's rows" do
    stats = crawl!

    assert_equal [ FILE, "EIA-860 annual generator ownership, 2025" ], [ stats["file"], source.title ]
    assert_equal({ "eia_plant_id" => "6011", "plant_name" => "Calvert Cliffs Nuclear Power Plant", "state" => "MD", "generator_id" => "1",
      "nameplate_mw" => "918", "ownership" => "S", "owner_eia_utility_id" => "55951", "owner_name" => "Constellation Nuclear",
      "percent_owned" => nil }, stored.find { |row| row["eia_plant_id"] == "6011" }, "sole owner: the reporting utility, no share stated")
    vogtle = stored.select { |row| row["eia_plant_id"] == "649" }
    assert_equal %w[4744 4744 7140 7140 13100 13100 13994 13994], vogtle.map { |row| row["owner_eia_utility_id"] }, "an owner's rows together"
    assert_equal %w[0.016 0.227 0.3 0.457], vogtle.map { |row| row["percent_owned"] }.uniq.sort, "without the workbook's float noise"
    assert_equal "1205.1", stored.find { |row| row["eia_plant_id"] == "6036" }["nameplate_mw"]
    assert_includes stored.map { |row| row["eia_plant_id"] }, "68635", "a proposed plant (Kemmerer)"
    assert_not_includes stored.map { |row| row["eia_plant_id"] }, "3", "not the coal plant"
    assert_equal 16, stats["rows"], "Vogtle 8, Calvert Cliffs 1, Catawba 4, Summer 2, Kemmerer 1"
  end

  test "a zip without the ownership workbook needs a human" do
    stub_request(:get, FILE).to_return(body: yearly_zip(owner_workbook: false))

    assert_equal "needs_human", crawl!["snapshot"]
    assert_match "No workbook matching", source.status_reason
  end

  test "proposes one owns claim per owner per plant, with its share, and each owner as a company with its EIA utility ID" do
    crawl!
    candidates = plugin.extract(source, nil)
    vogtle = links.select { |c| c[:payload]["facility"]["eia_plant_id"] == "649" }

    assert_equal({ "Georgia Power Co" => "45.7", "Oglethorpe Power Corporation" => "30", "Municipal Electric Authority - (GA)" => "22.7",
      "Dalton Utilities" => "1.6" }, vogtle.to_h { |c| [ c[:payload].dig("organization", "name"), c[:payload]["ownership_pct"] ] })
    assert_equal({ "organization" => { "name" => "Constellation Nuclear", "eia_utility_id" => "55951" },
      "facility" => { "eia_plant_id" => "6011", "name" => "Calvert Cliffs Nuclear Power Plant" }, "relationship_type" => "owns",
      "ownership_pct" => "100" }, links.find { |c| c[:payload]["facility"]["eia_plant_id"] == "6011" }[:payload])
    companies = candidates.select { |c| c[:kind] == "organization" }
    assert_equal 12, companies.size, "one per owner across the file"
    assert_equal({ "name" => "Oglethorpe Power Corporation", "eia_utility_id" => "13994" },
      companies.find { |c| c[:payload]["eia_utility_id"] == "13994" }[:payload])
    assert candidates.all? { |c| plugin.quote_in_source?(source, c[:quote]) }, "every quote is the stored rows, word for word"
    assert_equal 2, vogtle.first[:quote].lines.size, "an owner's rows for both units"
  end

  test "an owner whose share differs between units is claimed on each unit" do
    crawl!
    catawba = links.reject { |c| c[:payload]["facility"]["eia_plant_id"] }

    assert_equal [ [ "Catawba 1", "13630", "75" ], [ "Catawba 1", "15028", "25" ], [ "Catawba 2", "13683", "61.51" ], [ "Catawba 2", "5416", "38.49" ] ],
      catawba.map { |c| [ c[:payload]["facility"]["name"], c[:payload].dig("organization", "eia_utility_id"), c[:payload]["ownership_pct"] ] }.sort
  end

  test "end to end: shares that don't add up, per-unit claims and a new co-owner wait for a person; a plant's first owner doesn't" do
    run!

    calvert = claim("55951", "6011")
    assert_equal "recommend_publish", calvert.ai_recommendation, "Calvert Cliffs has no owner yet"
    summer = claim("17539", "6127")
    assert summer.status_needs_review?
    assert_match "add up to 96.67% in EIA's file, not 100%", summer.notes
    catawba = claim("13630", "Catawba 1")
    assert catawba.status_needs_review?
    assert_match "different shares for each unit", catawba.notes
    assert_equal @catawba1.id, Directory::Lookup.fact_attributes(type: "FacilityRelationship", id: catawba.subject_id)["facility_id"]
    oglethorpe = claim("13994", "649")
    assert oglethorpe.status_needs_review?
    assert_match "already has published owners", oglethorpe.notes
  end

  test "an owner is found by its EIA utility ID before its name" do
    oglethorpe = Organization.create!(name: "Oglethorpe", eia_utility_id: "13994", verification_status: "verified", verified_by: "human:tosin")
    run!

    company = Candidate.where(kind: "organization").find { |c| c.payload["eia_utility_id"] == "13994" }
    assert_equal [ "Organization", oglethorpe.id ], [ company.subject_type, company.subject_id ]
    assert_match "by EIA utility ID", company.notes
  end

  test "tells the verifier what the file is and what the ownership codes mean" do
    facts = plugin.source_facts(Source.new(url: SOURCE, source_kind: "eia_owners"))

    assert_match "S means the owner named is the utility that reports the generator, and owns it alone", facts
    assert_nil plugin.source_facts(Source.new(url: FILE, source_kind: "eia_plants"))
  end
end
