require "test_helper"
require_relative "../support/dummy_plugin"

# EIA-860's annual Plant file (#319): each nuclear plant's city. The zip and
# its plant workbook are built here, laid out like EIA's 2025 file (checked
# against the real one, 17 Oct 2026): a title row, then the header, one row
# per plant. Vogtle and Columbia are their real rows, cut to these columns.
# The Duane Arnold row is made up: the real 2025 file doesn't list the plant
# (retired in 2020), so it stands for any site found by name.
class DataQuality::Plugins::EiaPlantsTest < ActiveSupport::TestCase
  include ReviewHelpers
  Plugin = DataQuality::Plugins::EiaPlants
  PlantFile = Plugin::PlantFile
  FILE = "https://www.eia.gov/electricity/data/eia860/xls/eia8602025.zip"
  HEADER = [ "Utility ID", "Utility Name", "Plant Code", "Plant Name", "Street Address", "City", "State", "Zip", "County", "Latitude" ].freeze
  VOGTLE = [ "7140", "Georgia Power Co", "649", "Vogtle", "7821 River Road", "Waynesboro", "GA", "30830", "Burke", "33.142" ].freeze
  COLUMBIA = [ "6213", "Energy Northwest", "371", "Columbia Generating Station", "76 N Power Plant Loop", "Richland", "WA", "99352", "Benton", "46.47" ].freeze
  DUANE = [ "9999", "NextEra Energy Duane Arnold LLC", "1060", "Duane Arnold Energy Center", "3277 DAEC Road", "Palo", "IA", "52324", "Linn", "42.1" ].freeze
  COAL = [ "195", "Alabama Power Co", "3", "Barry", "North Highway 43", "Bucks", "AL", "36512", "Mobile", "31.0" ].freeze
  NO_CITY = [ "7140", "Georgia Power Co", "6051", "Hatch", "", "", "GA", "31513", "Appling", "31.9" ].freeze

  def plant_workbook(rows)
    cols = ("A".."J").to_a
    cell = ->(col, r, text) { %(<c r="#{col}#{r}" t="inlineStr"><is><t>#{text}</t></is></c>) }
    row = ->(r, values) { %(<row r="#{r}">#{values.each_with_index.map { |v, i| cell.(cols[i], r, v) unless v.empty? }.join}</row>) }
    sheet = [ row.(1, [ "Form EIA-860 Data - Schedule 2 - 'Plant Data'" ]), row.(2, HEADER), *rows.each_with_index.map { |v, i| row.(i + 3, v) } ]
    ns = %(xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("xl/workbook.xml")
      zip.write(%(<workbook #{ns} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">) +
        %(<sheets><sheet name="Plant" sheetId="1" r:id="rId1"/></sheets></workbook>))
      zip.put_next_entry("xl/_rels/workbook.xml.rels")
      zip.write(%(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) +
        %(<Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>))
      zip.put_next_entry("xl/worksheets/sheet1.xml")
      zip.write(%(<worksheet #{ns}><sheetData>#{sheet.join}</sheetData></worksheet>))
    end.string
  end

  def yearly_zip(rows = [ VOGTLE, COLUMBIA, DUANE, COAL, NO_CITY ])
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("1___Utility_Y2025.xlsx")
      zip.write("not read")
      zip.put_next_entry("2___Plant_Y2025.xlsx")
      zip.write(plant_workbook(rows))
    end.string
  end

  setup do
    stub_request(:get, "https://www.eia.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /private/\n")
    stub_request(:get, Plugin::INDEX_URL).to_return(body: <<~HTML)
      <a href="archive/xls/eia8602024.zip">2024</a>
      <a href="xls/eia8602025.zip">2025</a>
      <a href="xls/eia8602026ER.zip">2026 early release</a>
      <a href="https://evil.example/electricity/data/eia860/xls/eia8602030.zip">Elsewhere</a>
    HTML
    @file = stub_request(:get, FILE).to_return(body: yearly_zip)
    # Sites as the directory has them: Vogtle by EIA plant ID; Columbia and
    # Duane Arnold with none (Columbia is one record with its NRC docket).
    @vogtle = Facility.create!(name: "Plant Vogtle", eia_plant_id: "649", state: "GA", facility_type: "power_reactor",
      verification_status: "verified", verified_by: "human:tosin")
    @columbia = Facility.create!(name: "Columbia Generating Station", nrc_docket: "05000397", state: "WA",
      facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    @duane = Facility.create!(name: "Duane Arnold Energy Center", state: "IA", facility_type: "power_reactor",
      verification_status: "verified", verified_by: "human:tosin")
    Facility.create!(name: "Hatch", eia_plant_id: "6051", state: "GA", facility_type: "power_reactor")
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl! = plugin.crawl(CrawlRun.create!(stage: "crawl", source_kind: "eia_plants"))
  def source = Source.find_by!(url: FILE)
  def stored = CSV.parse(source.content_text, headers: true).map(&:to_h)

  def run!(verifier: PublishEverything.new)
    DataQuality::Pipeline.run("eia_plants", plugin:, only: %w[crawl extract match verify], verifier:)
  end

  test "is the plug-in for eia_plants" do
    assert_instance_of Plugin, DataQuality::Plugin.for("eia_plants")
  end

  test "reads the newest final yearly zip from EIA's own site, and keeps only nuclear plants' rows" do
    stats = crawl!

    assert_equal FILE, stats["file"]
    assert_equal "EIA-860 annual plant file, 2025", source.title
    assert_equal %w[649 371 1060 6051], stored.map { |row| row["eia_plant_id"] },
      "by EIA plant ID (Vogtle, Hatch), or by name and state (Columbia, Duane Arnold); not the coal plant"
    assert_equal({ "eia_plant_id" => "371", "plant_name" => "Columbia Generating Station", "street_address" => "76 N Power Plant Loop",
      "city" => "Richland", "state" => "WA", "zip" => "99352", "county" => "Benton" }, stored.second)
    assert_equal 4, stats["plants"]
  end

  test "a plant in EIA's newest monthly file is kept though no site has its ID yet" do
    Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/august_generator2026.xlsx", source_kind: "eia_generators",
      crawl_status: "ok", fetched_at: 1.day.ago, content_text: "eia_plant_id,plant_name\n3,Barry\n")
    crawl!

    assert_includes stored.map { |row| row["eia_plant_id"] }, "3"
  end

  test "fetches at most once a day, and a zip without the plant workbook needs a human" do
    crawl!
    crawl!
    assert_requested @file, times: 1

    source.update!(fetched_at: 1.day.ago)
    stub_request(:get, FILE).to_return(body: Zip::OutputStream.write_buffer { |zip| zip.put_next_entry("readme.txt") && zip.write("x") }.string)
    stats = crawl!
    assert_equal "needs_human", stats["snapshot"]
    assert_match "No plant workbook", source.reload.status_reason
  end

  test "a zip past the Fetcher's usual 20 MB is read, up to the plug-in's limit" do
    fetcher = DataQuality::Fetcher.new(sleeper: ->(_) { })
    seen = []
    fetcher.define_singleton_method(:get) do |url, **options|
      seen << options[:max_bytes] if url == FILE
      super(url, **options)
    end
    Plugin.new(fetcher:).crawl(CrawlRun.create!(stage: "crawl", source_kind: "eia_plants"))

    assert_equal [ Plugin::MAX_BYTES ], seen
    assert_operator Plugin::MAX_BYTES, :>, DataQuality::Fetcher::MAX_BYTES
  end

  test "proposes each plant's city with its row as the quote; a row with no city proposes nothing" do
    crawl!
    candidates = plugin.extract(source, nil).index_by { |candidate| candidate[:payload].dig("identify", "eia_plant_id") }

    assert_equal %w[1060 371 649], candidates.keys.sort, "Hatch's row has no city"
    assert_equal({ "identify" => { "eia_plant_id" => "649", "name" => "Vogtle" }, "city" => "Waynesboro" }, candidates["649"][:payload])
    assert_equal({ "identify" => { "eia_plant_id" => "371", "name" => "Columbia Generating Station", "site_id" => @columbia.id },
      "city" => "Richland" }, candidates["371"][:payload], "one record with its docket: it can't take a plant ID")
    assert_equal({ "identify" => { "eia_plant_id" => "1060", "name" => "Duane Arnold Energy Center", "site_id" => @duane.id },
      "city" => "Palo", "eia_plant_id" => "1060" }, candidates["1060"][:payload], "a site: its plant ID comes with the city")
    assert candidates.values.all? { |candidate| plugin.quote_in_source?(source, candidate[:quote]) }
    assert_equal stored.first.values.to_csv.chomp, candidates["649"][:quote]
  end

  test "end to end: a blank city is filled with the row as evidence; a plant found by name is held for a person" do
    run!
    vogtle = Candidate.find_by!(subject_type: "Facility", subject_id: @vogtle.id)
    assert_equal "recommend_publish", vogtle.ai_recommendation
    approve_recommended

    assert_equal "Waynesboro", @vogtle.reload.city
    assert_equal "Plant Vogtle", @vogtle.name, "never renamed"
    assert @vogtle.evidence.exists?(source: source, quote: vogtle.quote)

    columbia = Candidate.find_by!(subject_type: "Facility", subject_id: @columbia.id)
    duane = Candidate.find_by!(subject_type: "Facility", subject_id: @duane.id)
    assert [ columbia, duane ].all?(&:status_needs_review?), "found by name: held for a person"
    assert_match "can't take an EIA plant ID until it's split", columbia.notes
    assert_match "Approving sets that EIA plant ID and the city", duane.notes
    approved = DataQuality::Review.approve([ columbia.id, duane.id ], by: "human:tosin")
    assert approved.all? { |result| result.errors.empty? }, approved.flat_map(&:errors).to_sentence
    assert_equal [ "Richland", nil ], @columbia.reload.values_at(:city, :eia_plant_id)
    assert_equal [ "Palo", "1060" ], @duane.reload.values_at(:city, :eia_plant_id)
  end

  test "a city a person set is never overwritten: a different one comes back as a difference" do
    @vogtle.update!(city: "Augusta")
    run!
    candidate = Candidate.find_by!(subject_type: "Facility", subject_id: @vogtle.id)
    result = DataQuality::Review.approve([ candidate.id ], by: "human:tosin").sole

    assert_equal "Augusta", @vogtle.reload.city
    assert result.errors.any? || result.conflicts.any?, "the difference is reported, not written"
  end

  test "never creates a site: a plant row with no site waits" do
    Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/august_generator2026.xlsx", source_kind: "eia_generators",
      crawl_status: "ok", fetched_at: 1.day.ago, content_text: "eia_plant_id,plant_name\n3,Barry\n")

    assert_no_difference("Facility.count") { run! }
    assert_match "No site for EIA plant 3", Candidate.find { |c| c.payload.dig("identify", "eia_plant_id") == "3" }.notes
  end

  test "tells the verifier what the file is, for the file only" do
    assert_match "Plant sheet of EIA's annual Form EIA-860", plugin.source_facts(Source.new(url: FILE, source_kind: "eia_plants"))
    assert_nil plugin.source_facts(Source.new(url: Plugin::INDEX_URL, source_kind: Plugin::INDEX_SOURCE_KIND))
  end
end
