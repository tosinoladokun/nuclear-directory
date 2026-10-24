require "test_helper"
require_relative "../support/dummy_plugin"

# EIA-860's annual Plant file (#319): each nuclear plant's city. The zip and
# its workbooks are built here, laid out like EIA's 2025 file (checked
# against the real one, 17 and 19 Oct 2026): a title row, then the header,
# one row per plant (or generator). Vogtle and Columbia are their real
# rows, cut to these columns. The Duane Arnold row is made up: the real 2025
# file doesn't list the plant (retired in 2020), so it stands for any site
# found by name.
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
  ROBINSON = [ "3046", "Duke Energy Progress - (NC)", "3251", "H B Robinson", "3581 West Entrance Road", "Hartsville", "SC", "29550", "Darlington", "34.4" ].freeze
  KEMMERER = [ "65467", "US SFR Owner LLC", "68635", "Kemmerer Unit 1", "", "Kemmerer", "WY", "83101", "Lincoln", "41.8" ].freeze
  GENERATOR_HEADER = [ "Utility ID", "Utility Name", "Plant Code", "Plant Name", "State", "Generator ID", "Technology" ].freeze
  # [plant code, technology] per generator: the coal plant's isn't nuclear.
  OPERABLE = [ %w[649 Nuclear], %w[371 Nuclear], %w[1060 Nuclear], %w[6051 Nuclear], %w[3251 Nuclear], [ "3", "Conventional Steam Coal" ] ].freeze
  PROPOSED = [ %w[68635 Nuclear] ].freeze

  # An .xlsx with these sheets: { name => [title, header, *rows] }.
  def workbook(sheets)
    cell = ->(col, r, text) { %(<c r="#{col}#{r}" t="inlineStr"><is><t>#{text}</t></is></c>) }
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

  def plant_workbook(rows) = workbook("Plant" => [ [ "Form EIA-860 Data - Schedule 2 - 'Plant Data'" ], HEADER, *rows ])

  def generator_rows(generators) = generators.map { |code, technology| [ "1", "Utility", code, "Plant #{code}", "XX", "1", technology ] }

  def generator_workbook(operable = OPERABLE, proposed = PROPOSED)
    workbook("Operable" => [ [ "Form EIA-860 Data - Schedule 3 - 'Generator Data' (Operable Units Only)" ], GENERATOR_HEADER, *generator_rows(operable) ],
      "Proposed" => [ [ "Form EIA-860 Data - Schedule 3 - 'Generator Data' (Proposed Units Only)" ], GENERATOR_HEADER, *generator_rows(proposed) ])
  end

  def yearly_zip(rows = [ VOGTLE, COLUMBIA, DUANE, COAL, NO_CITY, ROBINSON, KEMMERER ], generators: generator_workbook)
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("1___Utility_Y2025.xlsx")
      zip.write("not read")
      zip.put_next_entry("2___Plant_Y2025.xlsx")
      zip.write(plant_workbook(rows))
      if generators
        zip.put_next_entry("3_1_Generator_Y2025.xlsx")
        zip.write(generators)
      end
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
    # Robinson and Kemmerer aren't in the directory.
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

  test "reads the newest final yearly zip from EIA's own site, and keeps the rows of plants with a nuclear generator" do
    stats = crawl!

    assert_equal FILE, stats["file"]
    assert_equal "EIA-860 annual plant file, 2025", source.title
    assert_equal %w[649 371 1060 6051 3251 68635], stored.map { |row| row["eia_plant_id"] },
      "operable or proposed (Kemmerer) nuclear generators, whether or not the directory has the plant; not the coal plant"
    assert_equal({ "eia_plant_id" => "371", "plant_name" => "Columbia Generating Station", "street_address" => "76 N Power Plant Loop",
      "city" => "Richland", "state" => "WA", "zip" => "99352", "county" => "Benton" }, stored.second)
    assert_equal 6, stats["plants"]
  end

  test "what's stored depends on the file alone: a site added after the first read still gets its row when the file is unchanged" do
    crawl!
    robinson = Facility.create!(name: "H. B. Robinson", eia_plant_id: "3251", state: "SC", facility_type: "power_reactor",
      verification_status: "verified", verified_by: "human:tosin")
    source.update!(fetched_at: 1.day.ago, etag: '"2025"')
    stub_request(:get, FILE).with(headers: { "If-None-Match" => '"2025"' }).to_return(status: 304)

    crawl!

    assert_equal "ok", source.reload.crawl_status
    payload = plugin.extract(source, nil).find { |candidate| candidate[:payload].dig("identify", "eia_plant_id") == "3251" }&.dig(:payload)
    assert_equal({ "identify" => { "eia_plant_id" => "3251", "name" => "H B Robinson", "state" => "SC" }, "city" => "Hartsville" }, payload)
    assert robinson.persisted?
  end

  test "fetches at most once a day, and a zip without the plant or generator workbook needs a human" do
    crawl!
    crawl!
    assert_requested @file, times: 1

    source.update!(fetched_at: 1.day.ago)
    stub_request(:get, FILE).to_return(body: Zip::OutputStream.write_buffer { |zip| zip.put_next_entry("readme.txt") && zip.write("x") }.string)
    stats = crawl!
    assert_equal "needs_human", stats["snapshot"]
    assert_match "No plant workbook", source.reload.status_reason

    source.update!(fetched_at: 1.day.ago)
    stub_request(:get, FILE).to_return(body: yearly_zip(generators: nil))
    crawl!
    assert_match "No generator workbook", source.reload.status_reason
  end

  test "a file with no nuclear generator is unreadable, not an empty list" do
    stub_request(:get, FILE).to_return(body: yearly_zip(generators: generator_workbook([ [ "3", "Conventional Steam Coal" ] ], [])))

    assert_equal "needs_human", crawl!["snapshot"]
    assert_match "No nuclear generators", source.status_reason
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

    assert_equal %w[1060 3251 371 649 68635], candidates.keys.sort, "Hatch's row has no city"
    assert_equal({ "identify" => { "eia_plant_id" => "649", "name" => "Vogtle", "state" => "GA" }, "city" => "Waynesboro" },
      candidates["649"][:payload], "match finds the site, by EIA plant ID or by name and state")
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

  test "match records what it found by name: the site and its plant ID, or only the site for a one-record plant" do
    run!

    columbia = Candidate.find_by!(subject_type: "Facility", subject_id: @columbia.id)
    duane = Candidate.find_by!(subject_type: "Facility", subject_id: @duane.id)
    assert_equal({ "eia_plant_id" => "371", "name" => "Columbia Generating Station", "state" => "WA", "site_id" => @columbia.id },
      columbia.payload["identify"])
    assert_nil columbia.payload["eia_plant_id"], "one record with its docket: it can't take a plant ID"
    assert_equal "1060", duane.payload["eia_plant_id"], "a site: its plant ID comes with the city"
  end

  test "a plant added after the file was read is still found by name, though the file isn't read again" do
    @duane.destroy!
    run!
    waiting = Candidate.find { |c| c.payload.dig("identify", "eia_plant_id") == "1060" }
    assert_match "No site for EIA plant 1060", waiting.notes

    duane = Facility.create!(name: "Duane Arnold Energy Center", state: "IA", facility_type: "power_reactor",
      verification_status: "verified", verified_by: "human:tosin")
    run! # the same file: not fetched or extracted again, only matched

    assert_requested @file, times: 1
    waiting.reload
    assert_equal [ "Facility", duane.id ], [ waiting.subject_type, waiting.subject_id ]
    assert waiting.status_needs_review?, "found by name: held for a person"
    assert_match "Approving sets that EIA plant ID and the city", waiting.notes
  end

  test "a city a person set is never overwritten: a different one goes to review with both cities, before any approval" do
    @vogtle.update!(city: "Augusta")
    run!
    candidate = Candidate.find_by!(subject_type: "Facility", subject_id: @vogtle.id)

    assert candidate.status_needs_review?, "never recommended over a person's city"
    assert_match "Augusta", candidate.notes
    assert_match "Waynesboro", candidate.notes
    assert_equal({ "city" => [ "Augusta", "Waynesboro" ] },
      (directory = DataQuality::DirectoryClient.new) && DataQuality::Differences.with_human_verified(candidate, directory.attached_record(candidate), directory:))
    assert_equal "Augusta", @vogtle.reload.city
  end

  test "never creates a site: a plant row with no site waits" do
    assert_no_difference("Facility.count") { run! }
    assert_match "No site for EIA plant 3251", Candidate.find { |c| c.payload.dig("identify", "eia_plant_id") == "3251" }.notes
  end

  test "a newer yearly file withdraws the older file's open claims and warns on ones waiting for a person" do
    older = Source.create!(url: "https://www.eia.gov/electricity/data/eia860/archive/xls/eia8602024.zip", source_kind: "eia_plants",
      crawl_status: "ok", content_text: "x", title: "EIA-860 annual plant file, 2024")
    open = Candidate.create!(source: older, kind: "facility", status: "matched", subject: @vogtle, payload: { "city" => "Waynesboro" }, quote: "x")
    held = Candidate.create!(source: older, kind: "facility", status: "needs_review", subject: @duane, notes: "Found by name",
      payload: { "city" => "Palo" }, quote: "x")

    assert_equal 1, crawl!["superseded"]
    crawl! && source.update!(fetched_at: 1.day.ago) && crawl!

    assert open.reload.status_rejected?
    assert held.reload.status_needs_review?, "a claim waiting for a person keeps its place"
    assert_equal "Found by name. A newer EIA-860 file exists: EIA-860 annual plant file, 2025", held.notes, "warned once"
  end

  test "tells the verifier what the file is, for the file only" do
    assert_match "Plant sheet of EIA's annual Form EIA-860", plugin.source_facts(Source.new(url: FILE, source_kind: "eia_plants"))
    assert_nil plugin.source_facts(Source.new(url: Plugin::INDEX_URL, source_kind: Plugin::INDEX_SOURCE_KIND))
  end

  test "a failed read of the EIA-860 page is reported though its cached copy is used, and a same-day rerun keeps it on Today" do
    crawl!
    Source.find_by!(url: Plugin::INDEX_URL).update!(fetched_at: 1.day.ago)
    stub_request(:get, Plugin::INDEX_URL).to_return(status: 503)

    first = crawl!
    assert_equal "error", first["index"]
    assert_equal FILE, first["file"], "the cached page still finds the file"

    second = crawl!
    assert_equal "skipped_recent", second["index"]
    runs = [ first, second ].map { |stats| CrawlRun.new(status: "succeeded", stats:) }
    assert_equal "a page didn't answer", Today.problem(runs)
  end

  test "a Plant sheet with no nuclear plant is unreadable: the last good copy and older claims stay" do
    crawl!
    good = source.content_text
    source.update!(fetched_at: 1.day.ago)
    stub_request(:get, FILE).to_return(body: yearly_zip([ COAL ]))

    assert_equal "needs_human", crawl!["snapshot"]
    assert_match "No row on the Plant sheet is a nuclear plant", source.reload.status_reason
    assert_equal good, source.content_text
  end
end
