require "test_helper"

# The fixtures are DOE's real HALEU pages, fetched 2026-10-22 with the
# Fetcher's user agent and cut to their main content.
class DataQuality::Plugins::DoeProgramsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::DoePrograms
  ENRICHMENT = "https://www.energy.gov/ne/haleu-enrichment-services".freeze
  DECONVERSION = "https://www.energy.gov/ne/haleu-deconversion-services".freeze
  ALLOCATION = "https://www.energy.gov/ne/us-department-energy-haleu-allocation-process".freeze
  FILES = { ENRICHMENT => "haleu-enrichment-services", DECONVERSION => "haleu-deconversion-services", ALLOCATION => "us-department-energy-haleu-allocation-process" }.freeze

  setup do
    stub_request(:get, "https://www.energy.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /admin/\n")
    @stubs = FILES.to_h { |url, file| [ url, stub_request(:get, url).to_return(body: html(file), headers: { "Content-Type" => "text/html" }) ] }
  end

  def html(file) = file_fixture("doe_programs/#{file}.html").read
  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def stored(url, content = html(FILES[url])) = Source.create!(url:, source_kind: "doe_programs", crawl_status: "ok",
    content_text: content, content_sha256: Digest::SHA256.hexdigest(content))
  def stored_again(url) = Source.find_by(url:) || stored(url)
  def links(url) = plugin.extract(stored_again(url), nil).select { |c| c[:kind] == "relationship" }
    .map { |c| [ c[:payload]["to_organization"]["name"], c[:payload]["relationship_type"], c[:payload]["description"] ] }

  test "is the plug-in for doe_programs" do
    assert_instance_of Plugin, DataQuality::Plugin.for("doe_programs")
  end

  test "crawls each page once a day and counts the companies it names" do
    run = crawl
    second = crawl

    assert_equal 4 + 2 + 6 + 11, run.stats["companies"]
    assert_equal %w[changed], run.stats.except("companies").values.uniq
    assert_equal %w[skipped_recent], second.stats.except("companies").values.uniq
    @stubs.each_value { |stub| assert_requested stub, times: 1 }
  end

  test "a blocked page is recorded and skipped" do
    stub_request(:get, ENRICHMENT).to_return(status: 403, body: "Forbidden")

    assert_equal "blocked", crawl.stats["DOE: HALEU enrichment services"]
    assert Source.find_by!(url: ENRICHMENT).crawl_blocked?
  end

  test "a page missing a list needs a person, and extract refuses it" do
    stub_request(:get, DECONVERSION).to_return(body: "<html><main><p>We moved things around.</p></main></html>")

    assert_equal "layout_changed", crawl.stats["DOE: HALEU deconversion services"]
    source = Source.find_by!(url: DECONVERSION)
    assert source.crawl_needs_human?
    assert_raises(Plugin::LayoutChanged) { plugin.extract(source, nil) }
  end

  test "enrichment: one DOE funds link per company, summing up every list that names it, quoting its first item" do
    selected = "HALEU enrichment services contract: selected in 2024 to bid on task orders"
    ordered = "HALEU enrichment services task order, finalized January 5, 2026"
    assert_equal [
      [ "American Centrifuge Operating, LLC", "funds", "#{selected}; #{ordered}" ],
      [ "General Matter Inc.", "funds", "#{selected}; #{ordered}" ],
      [ "Louisiana Energy Services, LLC", "funds", selected ],
      [ "Orano Federal Services, LLC", "funds", selected ]
    ], links(ENRICHMENT)
    context = plugin.verification_context(stored_again(ENRICHMENT), "General Matter Inc.")
    assert_match "DOE selected four companies", context
    assert_match "finalized task orders", context
    assert_match "General Matter ($900 million)", context
  end

  test "a company on two pages gets one link, from the first page, summing up both, and the verifier reads both" do
    crawl
    from_enrichment = plugin.extract(Source.find_by!(url: ENRICHMENT), nil).select { |c| c[:payload].dig("to_organization", "name").to_s.start_with?("Orano") }
    from_deconversion = plugin.extract(Source.find_by!(url: DECONVERSION), nil).select { |c| c[:payload].dig("to_organization", "name").to_s.start_with?("Orano") }

    assert_equal [ "HALEU enrichment services contract: selected in 2024 to bid on task orders; " \
      "HALEU deconversion services contract, to bid on deconversion work" ], from_enrichment.map { |c| c[:payload]["description"] }
    assert_empty from_deconversion, "the deconversion page proposes the company, not a second link"
    context = plugin.verification_context(Source.find_by!(url: ENRICHMENT), from_enrichment.sole[:quote])
    assert_match "awarded contracts with 6 companies", context
    assert_match "DOE selected four companies", context
  end

  test "a heading's date is read from the page: a changed date is a change, and the description follows it" do
    source = stored(ALLOCATION)
    moved = Source.new(url: ALLOCATION, content_text: source.content_text.sub("Round 3 Conditional Selections (July 23, 2026)", "Round 3 Conditional Selections (August 23, 2026)"))

    refute_equal plugin.rows_sha256(source), plugin.rows_sha256(moved)
    assert_includes plugin.extract(moved, nil).filter_map { |c| c[:payload]["description"] }, "Conditional HALEU allocation, round 3 (August 23, 2026)"
  end

  test "a list that's there but names no one is a changed layout, not a complete read" do
    emptied = Source.new(url: DECONVERSION, content_text: Nokogiri::HTML(html(FILES[DECONVERSION])).tap { |doc| doc.css("li").each(&:remove) }.to_html)

    assert_nil plugin.rows_sha256(emptied)
    assert_raises(Plugin::LayoutChanged) { plugin.extract(emptied, nil) }
  end

  test "allocations: DOE supplies HALEU to each conditional selection; a joint entry is two companies" do
    source = stored(ALLOCATION)
    candidates = plugin.extract(source, nil)
    names = candidates.select { |c| c[:kind] == "organization" }.map { |c| c[:payload]["name"] }

    assert_includes names, "Abilene Christian University"
    assert_includes names, "Natura Resources LLC"
    assert_equal 11, names.size
    assert candidates.all? { |c| plugin.quote_in_source?(source, c[:quote]) }
    assert candidates.select { |c| c[:kind] == "relationship" }.all? { |c| c[:payload]["relationship_type"] == "supplies" && c[:payload]["from_organization"] == { "name" => "U.S. Department of Energy" } }
    assert_match "Round 1 Conditional Selections", plugin.verification_context(source, "TRISO-X LLC")
    assert_match "HALEU allocation process", plugin.source_facts(source)
  end

  test "deconversion: six companies, no roles; the verifier reads that DOE awarded them contracts" do
    source = stored(DECONVERSION)
    candidates = plugin.extract(source, nil)
    assert_match "awarded contracts with 6 companies", plugin.verification_context(source, "Framatome Inc.")

    assert_equal 6, candidates.count { |c| c[:kind] == "organization" }
    assert_empty candidates.select { |c| c[:kind] == "organization_role" }
  end
end
