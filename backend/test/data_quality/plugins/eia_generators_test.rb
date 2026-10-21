require "test_helper"
require_relative "../support/dummy_plugin"

# EIA-860M enrichment (#61). The workbook fixture holds real rows from EIA's
# August 2026 file: Vogtle 1-4, Farley 1, Hope Creek 1, Salem 1, Columbia 2,
# Arkansas Nuclear One 1-2, and one coal plant.
class DataQuality::Plugins::EiaGeneratorsTest < ActiveSupport::TestCase
  include ReviewHelpers
  Plugin = DataQuality::Plugins::EiaGenerators
  Workbook = Plugin::Workbook
  INDEX = Plugin::INDEX_URL
  FILE = "https://www.eia.gov/electricity/data/eia860m/xls/august_generator2026.xlsx"

  setup do
    stub_request(:get, "https://www.eia.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /private/\n")
    stub_request(:get, INDEX).to_return(body: <<~HTML)
      <a href="xls/july_generator2026.xlsx">July 2026</a>
      <a href="xls/august_generator2026.xlsx">August 2026</a>
      <a href="archive/xls/december_generator2025.xlsx">December 2025</a>
    HTML
    stub_request(:get, FILE).to_return(body: file_fixture("eia/generators_sample.xlsx").binread)
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl! = plugin.crawl(CrawlRun.create!(stage: "crawl", source_kind: "eia_generators"))
  def source = Source.find_by!(url: FILE)

  # Enrichment attaches only to a verified NRC unit (#118); real NRC units
  # reach this point through their own publication pipeline, so the helper
  # creates them verified by default. Agent-verified by default, so EIA can
  # still fill in or overwrite the fixture's placeholder values (NRC state
  # for a border plant, say) without the protect_human_verified check
  # treating them as a person's decision. Tests that need a human decision
  # pass verified_by: "human:…" or call verify!/reject! themselves. Pass
  # verified: false to simulate a unit still in review.
  def nrc_unit(name, docket, state, verified: true, **attributes)
    status = verified ? { verification_status: "verified", verified_by: "agent:test", verified_at: Time.current } : {}
    Facility.create!(name: name, nrc_docket: docket, state: state, facility_type: "power_reactor", **status, **attributes)
  end

  # Extract, match and verify, then a human approves what verify recommended
  # (verify only recommends, #15). Returns the runs.
  def match_and_verify!(verifier: PublishEverything.new)
    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match verify], verifier: verifier)
      .tap { approve_recommended }
  end

  test "tells the verifier every row is a US nuclear power reactor and names the columns, for the file only" do
    facts = plugin.source_facts(Source.new(url: FILE, source_kind: "eia_generators"))

    [ "technology is Nuclear", "plant type: power reactor", "country code US", "Entity Name is the entity that reports" ]
      .each { |said| assert_includes facts, said }
    assert_includes facts, Plugin::Workbook::COLUMNS.values.join(", "), "in the stored CSV's order"
    assert_nil plugin.source_facts(Source.new(url: Plugin::INDEX_URL, source_kind: Plugin::INDEX_SOURCE_KIND))
  end

  test "reads only the nuclear rows, keeping EIA's values verbatim" do
    generators = Workbook.nuclear_generators(file_fixture("eia/generators_sample.xlsx").binread)

    assert_equal 10, generators.size, "the coal plant is left out"
    vogtle = generators.find { |g| g["plant_name"] == "Vogtle" && g["generator_id"] == "1" }
    assert_equal({ "state" => "GA", "net_summer_capacity_mw" => "1150", "eia_plant_id" => "649" },
      vogtle.slice("state", "net_summer_capacity_mw", "eia_plant_id"))
  end

  test "an unreadable file or a changed layout is reported, not guessed at" do
    assert_raises(Workbook::Unreadable) { Workbook.nuclear_generators("not a zip") }
  end

  test "crawl picks the newest monthly file and stores its nuclear rows" do
    stats = crawl!

    assert_equal FILE, stats["file"]
    assert_equal 10, stats["generators"]
    assert source.crawl_ok?
    assert_equal "EIA-860M generator inventory, August 2026", source.title
    assert_equal 11, source.content_text.lines.size, "header plus one line per generator"
  end

  # #118: FILE_LINK used to accept any word before _generator<year>.xlsx,
  # and Date::MONTHNAMES.index(non_month).to_i returned 0, so a bogus link
  # on EIA's page sorted as month 0 and could win over a real one.
  test "a link whose month isn't a real month name is ignored" do
    stub_request(:get, INDEX).to_return(body: <<~HTML)
      <a href="xls/xyz_generator2026.xlsx">Bogus</a>
      <a href="xls/august_generator2026.xlsx">August 2026</a>
    HTML
    assert_equal FILE, crawl!["file"]
  end

  test "only EIA's own https file links are followed, and never a redirect to another site" do
    stub_request(:get, INDEX).to_return(body: <<~HTML)
      <a href="https://127.0.0.1/xls/december_generator2030.xlsx">Elsewhere</a>
      <a href="//evil.example/electricity/data/eia860m/xls/november_generator2030.xlsx">Protocol-relative</a>
      <a href="http://www.eia.gov/electricity/data/eia860m/xls/october_generator2030.xlsx">Plain http</a>
      <a href="xls/august_generator2026.xlsx">August 2026</a>
    HTML
    assert_equal FILE, crawl!["file"]

    stub_request(:get, FILE).to_return(status: 302, headers: { "Location" => "http://169.254.169.254/latest" })
    Source.find_by!(url: FILE).update_columns(fetched_at: nil)
    crawl!
    assert_match "Not fetched: only https URLs are fetched", Source.find_by!(url: FILE).status_reason
    assert_not_requested :get, "http://169.254.169.254/latest"

    stub_request(:get, FILE).to_return(status: 302, headers: { "Location" => "https://169.254.169.254/latest" })
    Source.find_by!(url: FILE).update_columns(fetched_at: nil)
    crawl!
    assert_match "Not fetched: redirected to another host (169.254.169.254)", Source.find_by!(url: FILE).status_reason,
      "the shared Fetcher (#114) refuses it"
    assert_not_requested :get, "https://169.254.169.254/latest"
  end

  test "a newer monthly file withdraws the older file's unpublished candidates" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    waiting = Candidate.create!(source: july, kind: "facility", quote: "old row", payload: { "identify" => { "name" => "Vogtle" } })
    published = Candidate.create!(source: july, kind: "facility", quote: "older row", status: "merged", payload: {},
      subject_type: "Facility", subject_id: facilities(:vogtle).id)

    assert_equal 1, crawl!["superseded"]

    assert waiting.reload.status_rejected?
    assert_equal "Superseded by the newer EIA-860M generator inventory, August 2026", waiting.notes
    assert published.reload.status_merged?, "what's published stays"
  end

  test "a later month is never superseded by an earlier one, and review items only get a note" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    september = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/september_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    later = Candidate.create!(source: september, kind: "facility", quote: "later row", payload: {})
    in_review = Candidate.create!(source: july, kind: "facility", quote: "review row", payload: {}, status: "needs_review",
      notes: "Its site disagrees")

    crawl!

    assert later.reload.status_new?, "September is newer than the August file read now"
    assert in_review.reload.status_needs_review?
    assert_equal "Its site disagrees. A newer EIA file exists: EIA-860M generator inventory, August 2026", in_review.notes
  end

  # Like EIA's real file: text in a shared-strings table, and a sheet big
  # enough to be read in many chunks.
  def shared_strings_workbook(rows:)
    header = [ "Plant ID", "Plant Name", "Generator ID", "Plant State", "County", "Net Summer Capacity (MW)",
      "Nameplate Capacity (MW)", "Status", "Latitude", "Longitude", "Entity Name", "Technology" ]
    strings = header + [ "Vogtle", "GA", "Burke", "(OP) Operating", "Georgia Power", "Nuclear" ]
    index = strings.each_with_index.to_h
    cell = ->(col, row, text) { %(<c r="#{col}#{row}" t="s"><v>#{index.fetch(text)}</v></c>) }
    number = ->(col, row, value) { %(<c r="#{col}#{row}"><v>#{value}</v></c>) }
    cols = ("A".."L").to_a
    sheet_rows = [ %(<row r="1">#{header.each_with_index.map { |h, i| cell.(cols[i], 1, h) }.join}</row>) ]
    (2..rows + 1).each do |r|
      sheet_rows << %(<row r="#{r}">#{number.("A", r, 649)}#{cell.("B", r, "Vogtle")}#{number.("C", r, r)}#{cell.("D", r, "GA")}) +
        %(#{cell.("E", r, "Burke")}#{number.("F", r, 1150)}#{number.("G", r, 1215)}#{cell.("H", r, "(OP) Operating")}) +
        %(#{number.("I", r, 33.142)}#{number.("J", r, -81.762)}#{cell.("K", r, "Georgia Power")}#{cell.("L", r, "Nuclear")}</row>)
    end
    ns = %(xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main")
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("xl/workbook.xml")
      zip.write(%(<workbook #{ns} xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">) +
        %(<sheets><sheet name="Operating" sheetId="1" r:id="rId1"/></sheets></workbook>))
      zip.put_next_entry("xl/_rels/workbook.xml.rels")
      zip.write(%(<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">) +
        %(<Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>))
      zip.put_next_entry("xl/sharedStrings.xml")
      zip.write(%(<sst #{ns}>#{strings.map { |s| "<si><t>#{s}</t></si>" }.join}</sst>))
      zip.put_next_entry("xl/worksheets/sheet1.xml")
      zip.write(%(<worksheet #{ns}><sheetData>#{sheet_rows.join}</sheetData></worksheet>))
    end.string
  end

  # A trimmed copy of EIA's real August 2026 workbook: its title and header
  # rows, all 96 nuclear rows and 150 others, with their real cell markup and
  # a shared-strings table cut to what they use.
  test "EIA's real workbook (trimmed) gives all 96 nuclear generators" do
    generators = Workbook.nuclear_generators(file_fixture("eia/real_trimmed.xlsx").binread)

    assert_equal 96, generators.size
    assert_equal 96, generators.count { |g| g["eia_plant_id"].present? && g["generator_id"].present? && g["state"].present? }
    vogtle = generators.select { |g| g["plant_name"] == "Vogtle" }
    assert_equal %w[1 2 3 4], vogtle.map { |g| g["generator_id"] }.sort
    assert_equal [ "GA" ], vogtle.map { |g| g["state"] }.uniq
  end

  test "the chunked inflater reads every part of a workbook exactly as rubyzip does (#188)" do
    path = file_fixture("eia/real_trimmed.xlsx").to_s

    Zip::File.open(path) do |zip|
      File.open(path, "rb") do |file|
        zip.entries.reject(&:directory?).each do |entry|
          inflating = Workbook::Inflating.new(file, entry)
          streamed = +"".b
          while (chunk = inflating.read(1000)) # small reads, like the XML reader's
            streamed << chunk
          end
          assert_equal entry.get_input_stream.read.b, streamed, entry.name
        end
      end
    end
  end

  test "the chunked inflater reports a damaged part instead of reading it" do
    path = file_fixture("eia/real_trimmed.xlsx").to_s

    Zip::File.open(path) do |zip|
      File.open(path, "rb") do |file|
        sheet = zip.entries.max_by(&:size)
        wrong_crc = SimpleDelegator.new(sheet)
        def wrong_crc.crc = __getobj__.crc ^ 1

        error = assert_raises(Workbook::Unreadable) { Workbook::Inflating.new(file, wrong_crc).read(sheet.size + 1) }
        assert_match "damaged", error.message
      end
    end
  end

  test "a part that claims or reaches more than the limit is refused, not inflated" do
    path = file_fixture("eia/real_trimmed.xlsx").to_s

    Zip::File.open(path) do |zip|
      File.open(path, "rb") do |file|
        sheet = zip.entries.max_by(&:size)
        claims_too_much = SimpleDelegator.new(sheet)
        def claims_too_much.size = Workbook::Inflating::MAX_SIZE + 1
        assert_match "too large", assert_raises(Workbook::Unreadable) { Workbook::Inflating.new(file, claims_too_much) }.message

        claims_little = SimpleDelegator.new(sheet) # a crafted file can understate its size
        def claims_little.size = 1
        stub_const(Workbook::Inflating, :MAX_SIZE, sheet.size / 2) do
          assert_match "expands past", assert_raises(Workbook::Unreadable) { Workbook::Inflating.new(file, claims_little).read }.message
        end
      end
    end
  end

  test "a large workbook with shared strings reads every row, like EIA's real file" do
    generators = Workbook.nuclear_generators(shared_strings_workbook(rows: 3000))

    assert_equal 3000, generators.size
    assert_equal({ "plant_name" => "Vogtle", "state" => "GA", "entity_name" => "Georgia Power" },
      generators.last.slice("plant_name", "state", "entity_name"))
  end

  test "a damaged sheet inside the workbook is reported, not a crash" do
    bytes = Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry("xl/workbook.xml")
      zip.write("<workbook><sheets><sheet name=\"Operating\" r:id=\"rId1\"")
    end.string

    assert_raises(Workbook::Unreadable) { Workbook.nuclear_generators(bytes) }
  end

  test "a failed index fetch that falls back on yesterday's copy is reported, and Today flags it" do
    crawl!
    Source.where(url: [ INDEX, FILE ]).update_all(fetched_at: 2.days.ago)
    stub_request(:get, INDEX).to_return(status: 503)

    stats = crawl!
    assert_equal "error", stats["index"]
    assert_equal FILE, stats["file"], "yesterday's links still used"
    assert_equal "a page didn't answer", Today.problem([ CrawlRun.new(status: "succeeded", stats:) ])
  end

  test "a failed index read stays flagged after a same-day rerun that skips it" do
    crawl!
    Source.where(url: [ INDEX, FILE ]).update_all(fetched_at: 2.days.ago)
    stub_request(:get, INDEX).to_timeout

    failed = crawl!
    rerun = crawl!
    assert_equal "skipped_recent", rerun["index"]
    runs = [ failed, rerun ].map { |stats| CrawlRun.new(status: "succeeded", stats:) }
    assert_equal "a page didn't answer", Today.problem(runs)
  end

  test "EIA's index page is fetched at most once a day, like any source" do
    crawl!
    crawl!

    assert_requested :get, INDEX, times: 1
    assert_equal "eia_860m_index", Source.find_by!(url: INDEX).source_kind, "never extracted"
  end

  test "a unit match writes nothing until it's published" do
    unit = nrc_unit("Vogtle 1", "05000424", "GA")
    crawl!
    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match])

    assert_nil unit.reload.capacity_mw
    assert_empty unit.evidence
  end

  test "a rejected unit isn't enriched; the generator goes to review" do
    nrc_unit("Vogtle 1", "05000424", "GA").reject!(by: "agent:verifier/x")
    crawl!

    match_and_verify!

    vogtle_1 = Candidate.where(source: source).find { |c| c.payload["identify"]&.values_at("name", "unit") == %w[Vogtle 1] }
    assert vogtle_1.status_needs_review?
    assert_match "which was rejected", vogtle_1.notes
  end

  # #118: an unpublished unit is a person's decision (e.g. a merged-away
  # duplicate) that won't come back on its own, so the enrichment claim
  # settles instead of waiting forever on every run.
  test "an unpublished unit isn't enriched either; the generator goes to review" do
    nrc_unit("Vogtle 1", "05000424", "GA").unpublish!(by: "human:tosin")
    crawl!

    match_and_verify!

    vogtle_1 = Candidate.where(source: source).find { |c| c.payload["identify"]&.values_at("name", "unit") == %w[Vogtle 1] }
    assert vogtle_1.status_needs_review?
    assert_match "which was unpublished", vogtle_1.notes
  end

  test "a workbook that can't be read marks the source for a human" do
    stub_request(:get, FILE).to_return(body: "<html>maintenance</html>")

    assert_equal "needs_human", crawl!["snapshot"]
    assert source.crawl_needs_human?
    assert_match "Couldn't read the EIA workbook", source.status_reason

    assert source.fetched_at, "a file that can't be read still counts as today's fetch"
    crawl!
    assert_requested :get, FILE, times: 1
  end

  test "a number column holding something else is reported, not read as zero" do
    row = { "plant_name" => "Vogtle", "generator_id" => "1", "net_summer_capacity_mw" => "1150", "latitude" => "N/A" }

    error = assert_raises(Workbook::Unreadable) { Workbook.allocate.send(:check_numbers!, row) }
    assert_equal 'Latitude is "N/A" for Vogtle 1, not a number', error.message
    assert_nothing_raised { Workbook.allocate.send(:check_numbers!, row.merge("latitude" => "-81.76", "longitude" => nil)) }
  end

  test "a nuclear row missing its plant, state or generator is reported, not skipped" do
    row = { "eia_plant_id" => "649", "plant_name" => "Vogtle", "state" => nil, "generator_id" => nil }

    error = assert_raises(Workbook::Unreadable) { Workbook.allocate.send(:check_identity!, row) }
    assert_equal "A nuclear row has no Plant State, Generator ID (plant 649)", error.message
    assert Workbook.allocate.send(:check_identity!, row.merge("state" => "GA", "generator_id" => "1"))
  end

  test "extract quotes each generator's row verbatim and rounds the values" do
    crawl!
    candidates = plugin.extract(source, nil)

    farley = candidates.find { |c| c[:payload]["identify"]&.dig("name") == "Joseph M Farley" }
    assert_equal({ "name" => "Joseph M Farley", "state" => "AL", "unit" => "1", "eia_plant_id" => "6001" },
      farley[:payload]["identify"])
    assert_match(/\A\d+(\.\d)?\z/, farley[:payload]["capacity_mw"])
    assert_includes source.content_text, farley[:quote]
  end

  test "values land on the matching NRC unit, by state, name and unit number" do
    vogtle_1 = nrc_unit("Vogtle 1", "05000424", "GA")
    vogtle_3 = nrc_unit("Vogtle 3", "05200025", "GA")
    farley = nrc_unit("Farley 1", "05000348", "AL")
    hope_creek = nrc_unit("Hope Creek 1", "05000354", "NJ")
    salem = nrc_unit("Salem 1", "05000272", "NJ")
    crawl!

    match_and_verify!

    assert_equal 1150, vogtle_1.reload.capacity_mw
    assert vogtle_3.reload.capacity_mw.positive?
    assert farley.reload.latitude.present?
    assert hope_creek.reload.capacity_mw.positive?, "PSEG Hope Creek Generating Station → Hope Creek 1"
    assert_not_equal hope_creek.capacity_mw, salem.reload.capacity_mw, "two NJ plants kept apart"
    assert_equal [ "Vogtle 1" ], [ vogtle_1.name ], "EIA never renames"
  end

  test "an enriched unit goes under the site for its EIA plant, one site per plant" do
    farley = nrc_unit("Farley 1", "05000348", "AL")
    crawl!

    match_and_verify!

    site = Facility.find_by!(eia_plant_id: "6001")
    assert_equal site.id, farley.reload.parent_id
    assert_nil site.nrc_docket
  end

  test "a unit that already has a site keeps it" do
    seed_site = Facility.create!(name: "Farley Seed Site")
    farley = nrc_unit("Farley 1", "05000348", "AL", parent: seed_site)
    crawl!

    match_and_verify!

    assert_equal seed_site.id, farley.reload.parent_id
  end

  test "a site assigned after the lookup isn't replaced when the unit is grouped" do
    eia_site = Facility.create!(name: "Joseph M Farley", eia_plant_id: "6001")
    seed_site = Facility.create!(name: "Farley Seed Site")
    farley = nrc_unit("Farley 1", "05000348", "AL", parent: seed_site)
    candidate = Candidate.create!(source: Source.create!(url: "https://example.com/eia", source_kind: "eia_generators"), kind: "facility", quote: "row",
      status: "merged", subject_type: "Facility", subject_id: farley.id, payload: { "identify" => { "eia_plant_id" => "6001" } })
    stale = DataQuality::DirectoryClient.new
    stale.define_singleton_method(:site_for_unit) { |_| eia_site.id }

    stale.group_unit(candidate)

    assert_equal seed_site.id, farley.reload.parent_id
  end

  test "a unit isn't put under a rejected site" do
    Facility.create!(name: "Joseph M Farley", eia_plant_id: "6001").reject!(by: "human:tosin")
    farley = nrc_unit("Farley 1", "05000348", "AL")
    crawl!

    match_and_verify!

    assert_nil farley.reload.parent_id
  end

  test "units enriched before #73 are grouped by the one-off task" do
    farley = nrc_unit("Farley 1", "05000348", "AL")
    crawl!
    match_and_verify!
    farley.reload.update_columns(parent_id: nil)

    Rails.application.load_tasks unless Rake::Task.task_defined?("data_quality:group_units")
    assert_output(/Grouped 1 units/) { Rake::Task["data_quality:group_units"].execute }

    assert_equal Facility.find_by!(eia_plant_id: "6001").id, farley.reload.parent_id
  end

  test "a single-unit plant takes EIA's generator whatever its number" do
    columbia = nrc_unit("Columbia Generating Station", "05000397", "WA")
    crawl!

    match_and_verify!

    assert columbia.reload.capacity_mw.positive?, "EIA lists Columbia as generator 2"
  end

  test "EIA never creates units and doesn't change a unit's verification" do
    unit = nrc_unit("Vogtle 1", "05000424", "GA")
    crawl!

    assert_no_difference "Facility.where.not(nrc_docket: nil).count" do
      match_and_verify!
    end

    assert unit.reload.verified?, "EIA values don't re-decide the NRC unit"
    assert_equal [ "crawler" ], unit.evidence.distinct.pluck(:found_by)
  end

  # #118: enriching a pending unit would push EIA's values onto a record
  # that isn't public yet. Wait instead, as for a unit that doesn't exist.
  test "EIA waits for a pending NRC unit; values don't attach to a record that isn't public yet (#118)" do
    pending_unit = nrc_unit("Vogtle 1", "05000424", "GA", verified: false)
    crawl!
    match_and_verify!

    assert pending_unit.reload.pending?
    assert_empty pending_unit.evidence, "no values attached until the NRC unit is verified"
    waiting = Candidate.where(source: source).find { |c| c.payload["identify"]&.values_at("name", "unit") == %w[Vogtle 1] }
    assert waiting.status_new?
    assert_match "isn't verified yet", waiting.notes
  end

  test "each plant proposes its site and no operator: Entity Name is the reporting utility (#121, #227)" do
    crawl!
    candidates = plugin.extract(source, nil)

    site = candidates.find { |c| c[:kind] == "facility" && c[:payload]["eia_plant_id"] == "649" }
    assert_equal({ "name" => "Vogtle", "eia_plant_id" => "649", "facility_type" => "power_reactor", "state" => "GA" },
      site[:payload].slice("name", "eia_plant_id", "facility_type", "state"))
    assert_includes source.content_text, site[:quote]
    assert_equal 1, candidates.count { |c| c[:kind] == "facility" && c[:payload]["eia_plant_id"] == "649" }, "one site per plant"
    assert_equal [ "facility" ], candidates.map { |c| c[:kind] }.uniq, "no company, no operates link"
  end

  test "an EIA site isn't matched to an NRC unit of the same name, and units never take an EIA plant ID" do
    unit = nrc_unit("Joseph M Farley", "05000348", "AL")
    crawl!
    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match])

    farley = Candidate.where(source: source, kind: "facility").find { |c| c.payload["eia_plant_id"] == "6001" }
    assert farley.status_matched?, farley.notes
    assert_not_equal unit.id, farley.subject_id, "a new site, not the NRC unit"
    assert_nil unit.reload.eia_plant_id
    assert_not unit.tap { |u| u.eia_plant_id = "6001" }.valid?, "a docketed unit can't carry the plant ID"
  end

  test "an NRC unit named like a site doesn't hide the site from an EIA plant" do
    nrc_unit("Joseph M Farley", "05000348", "AL")
    site = Facility.create!(name: "Joseph M Farley")
    crawl!
    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match])

    farley = Candidate.where(source: source, kind: "facility").find { |c| c.payload["eia_plant_id"] == "6001" }
    assert_equal site.id, farley.subject_id, farley.notes
    assert_equal 1, Facility.where(name: "Joseph M Farley", nrc_docket: nil).count, "no second site"
    assert_equal site.id, Directory::FactWriter.write(:facility, { name: "Joseph M Farley", eia_plant_id: "6001" }).id
  end

  test "withdrawing an older month's candidates retires what only they proposed" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    proposed = Facility.create!(name: "Gone Plant", eia_plant_id: "99999")
    Candidate.create!(source: july, kind: "facility", quote: "old", status: "matched", proposed_subject: true,
      payload: { "name" => "Gone Plant", "eia_plant_id" => "99999" }, subject_type: "Facility", subject_id: proposed.id)

    crawl!

    assert proposed.reload.rejected?, "nothing current points at it"
  end

  test "a proposal is retired when it leaves the file, months after the candidate that proposed it" do
    june = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/june_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    proposed = Facility.create!(name: "Gone Plant", eia_plant_id: "99999")
    payload = { "name" => "Gone Plant", "eia_plant_id" => "99999" }
    Candidate.create!(source: june, kind: "facility", quote: "june", status: "rejected", proposed_subject: true,
      payload:, subject_type: "Facility", subject_id: proposed.id)
    Candidate.create!(source: july, kind: "facility", quote: "july", status: "matched", proposed_subject: false,
      payload:, subject_type: "Facility", subject_id: proposed.id)

    crawl!

    assert proposed.reload.rejected?, "June proposed it; July only attached; August no longer lists it"
  end

  # Before #227, EIA proposed each plant's Entity Name as its operator.
  def operator_claims(source, status:)
    farley = Facility.create!(name: "Joseph M Farley", eia_plant_id: "6001")
    company = Organization.create!(name: "Alabama Power Co")
    link = FacilityRelationship.create!(organization: company, facility: farley, relationship_type: "operates")
    [
      Candidate.create!(source:, kind: "organization", quote: "old", status:, proposed_subject: true,
        payload: { "name" => "Alabama Power Co" }, subject_type: "Organization", subject_id: company.id),
      Candidate.create!(source:, kind: "facility_relationship", quote: "old", status:, proposed_subject: true,
        payload: { "organization" => { "name" => "Alabama Power Co" }, "facility" => { "eia_plant_id" => "6001" },
          "relationship_type" => "operates" }, subject_type: "FacilityRelationship", subject_id: link.id)
    ]
  end

  test "open operator claims are withdrawn on the next crawl, with what only they proposed (#227)" do
    august = Source.create!(url: FILE, source_kind: "eia_generators")
    claims = operator_claims(august, status: "matched")
    # Reopened by the #226 repair: its ends not settled, so no link yet.
    reopened = Candidate.create!(source: august, kind: "facility_relationship", quote: "old", status: "new",
      payload: { "organization" => { "name" => "Southern Co" }, "facility" => { "eia_plant_id" => "649" }, "relationship_type" => "operates" })
    in_review = Candidate.create!(source: august, kind: "organization", quote: "old", status: "needs_review", payload: { "name" => "Entergy" })
    site = Candidate.create!(source: august, kind: "facility", quote: "old", status: "needs_review", payload: { "name" => "Vogtle", "eia_plant_id" => "649" })

    stats = crawl!

    [ *claims, reopened, in_review ].each do |claim|
      assert claim.reload.status_rejected?, claim.kind
      assert_match "not the plant's operator", claim.notes
    end
    assert site.reload.status_needs_review?, "sites are still EIA's to propose"
    assert Organization.find(claims.first.subject_id).rejected?, "the company only EIA proposed"
    assert FacilityRelationship.find(claims.last.subject_id).rejected?, "and its link"
    assert_equal 4, stats["operator_claims_withdrawn"]
    assert_nil crawl!["operator_claims_withdrawn"], "nothing left to withdraw"
  end

  test "the claims are locked before they're withdrawn, so a decision made at the same moment isn't overwritten" do
    operator_claims(Source.create!(url: FILE, source_kind: "eia_generators"), status: "matched")
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    plugin.send(:withdraw_operator_claims, CrawlRun.create!(stage: "crawl", source_kind: "eia_generators"))

    ActiveSupport::Notifications.unsubscribe(subscriber)
    locking = queries.index { |sql| sql.include?("candidates") && sql.include?("FOR UPDATE") }
    withdrawing = queries.index { |sql| sql.start_with?("UPDATE \"candidates\"") }
    assert locking, "the open claims are selected FOR UPDATE"
    assert_operator locking, :<, withdrawing
  end

  test "a record is locked before it's checked for other candidates and retired" do
    company_claim, = operator_claims(Source.create!(url: FILE, source_kind: "eia_generators"), status: "matched")
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| queries << payload[:sql] }

    plugin.send(:withdraw_operator_claims, CrawlRun.create!(stage: "crawl", source_kind: "eia_generators"))

    ActiveSupport::Notifications.unsubscribe(subscriber)
    locking = queries.index { |sql| sql.include?("FROM \"organizations\"") && sql.include?("FOR UPDATE") }
    checking = queries.index { |sql| sql.include?("\"candidates\".\"proposed_subject\"") }
    assert locking, "the company is locked"
    assert_operator locking, :<, checking, "before its other candidates are checked"
    assert Organization.find(company_claim.subject_id).rejected?
  end

  test "operator claims are withdrawn even when EIA's page can't be read" do
    stub_request(:get, INDEX).to_return(status: 503)
    claims = operator_claims(Source.create!(url: FILE, source_kind: "eia_generators"), status: "new")

    assert_raises(RuntimeError) { crawl! }

    assert claims.all? { |claim| claim.reload.status_rejected? }
  end

  test "an unreadable workbook still reports the claims it withdrew" do
    stub_request(:get, FILE).to_return(body: "not a zip")
    operator_claims(Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators"), status: "matched")

    stats = crawl!

    assert_equal [ "needs_human", 2 ], stats.values_at("snapshot", "operator_claims_withdrawn")
  end

  test "a published operator link, and a company something else uses, are left for a person" do
    august = Source.create!(url: FILE, source_kind: "eia_generators")
    company_claim, link_claim = operator_claims(august, status: "merged")
    company = Organization.find(company_claim.subject_id)
    Candidate.create!(source: Source.create!(url: "https://www.nrc.gov/list", source_kind: "nrc_reactor_list"), kind: "organization",
      quote: "nrc", status: "matched", payload: { "name" => "Alabama Power Co" }, subject_type: "Organization", subject_id: company.id)
    still_open = Candidate.create!(source: august, kind: "organization", quote: "old", status: "matched",
      payload: { "name" => "Alabama Power Co" }, subject_type: "Organization", subject_id: company.id)

    crawl!

    assert still_open.reload.status_rejected?
    assert link_claim.reload.status_merged?, "published: bin/rails directory:retire_eia_operators"
    assert company.reload.pending?, "published, and NRC's candidate points at it too"
  end

  test "withdrawal and retirement are one transaction, so a stopped run retries both" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    proposed = Facility.create!(name: "Gone Plant", eia_plant_id: "99999")
    withdrawn = Candidate.create!(source: july, kind: "facility", quote: "old", status: "matched", proposed_subject: true,
      payload: { "name" => "Gone Plant", "eia_plant_id" => "99999" }, subject_type: "Facility", subject_id: proposed.id)
    crawl!
    withdrawn.update_columns(status: "matched")
    proposed.update_columns(verification_status: "pending")
    stopping = DataQuality::DirectoryClient.new
    def stopping.retire(*, **) = raise("stopped")

    DataQuality::DirectoryClient.define_singleton_method(:new) { |*, **| stopping }
    begin
      assert_raises(RuntimeError) { plugin.send(:supersede_older_files, source, CrawlRun.create!(stage: "crawl", source_kind: "eia_generators")) }
    ensure
      DataQuality::DirectoryClient.singleton_class.remove_method(:new)
    end

    assert withdrawn.reload.status_matched?, "rolled back, so the next run withdraws it again"
  end

  test "a retirement that fails without raising also undoes the withdrawal" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    proposed = Facility.create!(name: "Gone Plant", eia_plant_id: "99999")
    withdrawn = Candidate.create!(source: july, kind: "facility", quote: "old", status: "matched", proposed_subject: true,
      payload: { "name" => "Gone Plant", "eia_plant_id" => "99999" }, subject_type: "Facility", subject_id: proposed.id)
    crawl!
    withdrawn.update_columns(status: "matched")
    proposed.update_columns(verification_status: "pending")
    failing = DataQuality::DirectoryClient.new
    def failing.retire(*, **) = DataQuality::DirectoryClient::WriteResult.new(ref: nil, errors: [ "invalid" ])

    DataQuality::DirectoryClient.define_singleton_method(:new) { |*, **| failing }
    begin
      error = assert_raises(RuntimeError) { plugin.send(:supersede_older_files, source, CrawlRun.create!(stage: "crawl", source_kind: "eia_generators")) }
    ensure
      DataQuality::DirectoryClient.singleton_class.remove_method(:new)
    end

    assert_match "Couldn't retire Facility", error.message
    assert withdrawn.reload.status_matched?
    assert proposed.reload.pending?
  end

  test "an operates link is retired when its plant stays but its operator changes" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    farley = Facility.create!(name: "Joseph M Farley", eia_plant_id: "6001")
    old_operator = Organization.create!(name: "Old Operator Co")
    link = FacilityRelationship.create!(organization: old_operator, facility: farley, relationship_type: "operates")
    Candidate.create!(source: july, kind: "facility_relationship", quote: "old", status: "matched", proposed_subject: true,
      payload: { "organization" => { "name" => "Old Operator Co" }, "facility" => { "eia_plant_id" => "6001" },
        "relationship_type" => "operates" },
      subject_type: "FacilityRelationship", subject_id: link.id)

    crawl!

    assert link.reload.rejected?, "August lists Farley under another operator"
    assert farley.reload.pending?, "the plant itself is still listed"
  end

  test "a plant still in the newer file keeps its proposal, which the newer file then matches" do
    july = Source.create!(url: "https://www.eia.gov/electricity/data/eia860m/xls/july_generator2026.xlsx",
      source_kind: "eia_generators", crawl_status: "ok")
    farley = Facility.create!(name: "Joseph M Farley", eia_plant_id: "6001")
    Candidate.create!(source: july, kind: "facility", quote: "old", status: "matched", proposed_subject: true,
      payload: { "name" => "Joseph M Farley", "eia_plant_id" => "6001" }, subject_type: "Facility", subject_id: farley.id)

    crawl!
    assert farley.reload.pending?, "Farley is in the August file too"

    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match])
    august = Candidate.where(source: source, kind: "facility").find { |c| c.payload["eia_plant_id"] == "6001" }
    assert_equal [ farley.id, "Matched existing Joseph M Farley (by EIA plant ID)" ], [ august.subject_id, august.notes ]
  end

  test "an EIA plant is proposed once, then found by its plant ID; a seed site's look-alike goes to review" do
    facilities(:vogtle).update!(name: "Plant Vogtle")
    crawl!
    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match])

    vogtle = Candidate.where(source: source, kind: "facility").find { |c| c.payload["eia_plant_id"] == "649" }
    assert vogtle.status_needs_review?, "Vogtle looks like the seed's Plant Vogtle: a human decides"
    farley = Candidate.where(source: source, kind: "facility").find { |c| c.payload["eia_plant_id"] == "6001" }
    assert farley.status_matched?
    assert_equal "6001", Facility.find(farley.subject_id).eia_plant_id

    # Extract again (as for a changed file), and the plant is found by its ID.
    source.update_columns(extracted_sha256: nil, extracted_rows_sha256: nil)
    assert_no_difference "Facility.count" do
      DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: %w[extract match])
    end
    again = Candidate.where(source: source, kind: "facility").where.not(id: farley.id).find { |c| c.payload["eia_plant_id"] == "6001" }
    assert_equal farley.subject_id, again.subject_id, "found by its plant ID"
    # The proposal is still waiting for a person, so the repeat closes instead of queueing twice (#240).
    assert_equal [ "confirmed", "Same as candidate ##{farley.id}, already waiting for review" ], [ again.status, again.notes ]
  end

  test "generators without an NRC unit yet wait and are retried" do
    crawl!
    runs = match_and_verify!

    waiting = Candidate.where(source: source).where("payload ? 'identify'")
    assert waiting.all?(&:status_new?)
    assert_equal 10, runs[1].stats["waiting"]

    nrc_unit("Vogtle 2", "05000425", "GA")
    DataQuality::Pipeline.run("eia_generators", plugin: plugin, only: "match")
    assert_equal 1, waiting.status_matched.count
  end

  test "a border plant NRC lists under a nearby city's state still matches, by the stricter rule" do
    # NRC's list gives Salem and Hope Creek the state of Wilmington, DE.
    salem = nrc_unit("Salem 1", "05000272", "DE")
    hope_creek = nrc_unit("Hope Creek 1", "05000354", "DE")
    crawl!

    match_and_verify!

    assert salem.reload.capacity_mw.positive?
    assert hope_creek.reload.capacity_mw.positive?
    assert_not_equal salem.capacity_mw, hope_creek.capacity_mw
  end

  test "a unit whose NRC record doesn't exist yet waits, even if its siblings do" do
    nrc_unit("Vogtle 3", "05200025", "GA")
    nrc_unit("Vogtle 4", "05200026", "GA")
    crawl!

    match_and_verify!

    vogtle_1 = Candidate.where(source: source).find { |c| c.payload["identify"]&.values_at("name", "unit") == %w[Vogtle 1] }
    assert vogtle_1.status_new?
    assert_match "retried on the next match run", vogtle_1.notes
  end

  test "two units that fit equally well go to review" do
    nrc_unit("Arkansas Nuclear 1", "05000313", "AR")
    nrc_unit("Arkansas River 1", "05000999", "AR")
    crawl!

    match_and_verify!(verifier: DataQuality::Verifiers::ReviewEverything.new)

    ano = Candidate.where(source: source).find { |c| c.payload["identify"]&.values_at("name", "unit") == [ "Arkansas Nuclear One", "1" ] }
    assert ano.status_needs_review?
    assert_match "could be Arkansas Nuclear 1 or Arkansas River 1", ano.notes
  end

  test "the closest name wins over a looser one" do
    exact = nrc_unit("Arkansas Nuclear One 1", "05000313", "AR")
    nrc_unit("Arkansas Nuclear 1", "05000999", "AR")
    crawl!

    match_and_verify!

    assert exact.reload.capacity_mw.positive?, "shares 'arkansas' and 'one' with EIA's name, not just 'arkansas'"
  end

  test "units without a state still match, and take EIA's state" do
    salem = nrc_unit("Salem 1", "05000272", nil)
    hope_creek = nrc_unit("Hope Creek 1", "05000354", nil)
    crawl!

    match_and_verify!

    assert_equal [ "NJ", "NJ" ], [ salem.reload.state, hope_creek.reload.state ]
    assert salem.capacity_mw.positive?
  end

  test "a verified unit's coordinates fill its site's blank ones" do
    facilities(:vogtle).destroy!
    site = Facility.create!(name: "Plant Vogtle Units 3 & 4")
    nrc_unit("Vogtle 3", "05200025", "GA", parent: site).verify!(by: "agent:verifier/nrc") # only a verified unit speaks for its site
    crawl!

    match_and_verify!

    assert site.reload.latitude.present?
    assert_nil site.capacity_mw, "capacity stays per unit"
  end
end
