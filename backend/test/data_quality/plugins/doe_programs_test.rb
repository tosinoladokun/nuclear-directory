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
  def links(url) = plugin.extract(stored(url), nil).select { |c| c[:kind] == "relationship" }
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

  test "enrichment: each company DOE selected, and each task order, funded by DOE, quoting its item" do
    assert_equal [
      [ "American Centrifuge Operating, LLC", "funds", "HALEU enrichment services contract: selected in 2024 to bid on task orders" ],
      [ "General Matter Inc.", "funds", "HALEU enrichment services contract: selected in 2024 to bid on task orders" ],
      [ "Louisiana Energy Services, LLC", "funds", "HALEU enrichment services contract: selected in 2024 to bid on task orders" ],
      [ "Orano Federal Services, LLC", "funds", "HALEU enrichment services contract: selected in 2024 to bid on task orders" ],
      [ "American Centrifuge Operating", "funds", "HALEU enrichment services task order, finalized January 5, 2026" ],
      [ "General Matter", "funds", "HALEU enrichment services task order, finalized January 5, 2026" ]
    ], links(ENRICHMENT)
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

  test "deconversion: six companies, no roles" do
    candidates = plugin.extract(stored(DECONVERSION), nil)

    assert_equal 6, candidates.count { |c| c[:kind] == "organization" }
    assert_empty candidates.select { |c| c[:kind] == "organization_role" }
  end
end
