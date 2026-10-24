require "test_helper"

# The fixtures are NRC's real list of power reactor units and three unit
# pages (fetched 2026-10-22 with the plug-in's user agent), each unit page
# cut to its key facts.
class DataQuality::Plugins::NrcReactorVendorsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcReactorVendors
  UNITS = "https://www.nrc.gov/facilities-safety/facility-finder/reactors/".freeze
  ANO1 = "Arkansas Nuclear One, Unit 1 | Docket Number: 05000313 | Reactor Vendor/Type: Babcock & Wilcox Lowered Loop".freeze

  setup do
    stub_request(:get, "https://www.nrc.gov/robots.txt").to_return(body: file_fixture("nrc/robots.txt").read)
    @pages = stub_request(:get, /\A#{Regexp.escape(UNITS)}/).to_return do |request|
      slug = request.uri.path.split("/").last
      file = Rails.root.join("test/fixtures/files/nrc/units/#{slug}.html")
      file.exist? ? { body: file.read } : { body: "<html><main><h1>#{slug}</h1><p><strong>Reactor Vendor/Type:</strong> Westinghouse Two-Loop<br></p></main></html>" }
    end
    Source.create!(url: DataQuality::Plugins::NrcReactorList::LIST_URL, source_kind: "nrc_reactor_list", crawl_status: "ok",
      content_text: file_fixture("nrc/list-power-reactor-units.html").read, content_sha256: "x")
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def page(slug) = Source.find_by!(url: "#{UNITS}#{slug}")

  test "is the plug-in for nrc_reactor_vendors" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_reactor_vendors")
  end

  test "reads every unit page the reactor list links, once a day, storing only name, docket and vendor line" do
    run = crawl
    second = crawl

    assert_equal 93, run.stats["units"]
    assert_equal({ "changed" => 93 }, run.stats["unit_pages"])
    assert_equal({ "skipped_recent" => 93 }, second.stats["unit_pages"])
    assert_requested @pages, times: 93
    assert_equal ANO1, page("ano1").content_text
    refute_match(/Operator|Public Affairs/, page("ano1").content_text)
  end

  test "no reactor list yet: nothing is read" do
    Source.delete_all
    assert_equal({ "units" => "no reactor list yet" }, crawl.stats)
  end

  test "a blocked unit page stops the crawl" do
    stub_request(:get, /\A#{Regexp.escape(UNITS)}/).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)

    stats = crawl.stats
    assert_equal({ "blocked" => 1 }, stats["unit_pages"])
    assert_equal "unit page blocked", stats["stopped"]
  end

  test "a page without a vendor line needs a person" do
    stub_request(:get, /\A#{Regexp.escape(UNITS)}/).to_return(body: "<html><main><p>Moved</p></main></html>")

    assert_equal 93, crawl.stats["unit_pages"]["needs_human"]
    assert page("ano1").crawl_needs_human?
    assert_empty plugin.extract(page("ano1"), nil)
  end

  test "each unit's vendor as the page names it, linked vendor_for to the unit by docket" do
    crawl

    assert_equal [
      { kind: "organization", quote: ANO1, payload: { "name" => "Babcock & Wilcox" } },
      { kind: "facility_relationship", quote: ANO1, payload: { "organization" => { "name" => "Babcock & Wilcox" },
        "facility" => { "name" => "Arkansas Nuclear One, Unit 1", "nrc_docket" => "05000313" }, "relationship_type" => "vendor_for" } }
    ], plugin.extract(page("ano1"), nil)
    assert_equal "Combustion Engineering", plugin.extract(page("palo1"), nil).first[:payload]["name"], "a historical vendor keeps its name"
    assert_equal "Westinghouse", plugin.extract(page("vog1"), nil).first[:payload]["name"]
    assert plugin.quote_in_source?(page("ano1"), ANO1)
  end

  test "a vendor line naming no known vendor proposes nothing, and a page that changes to one sends its published link to a person" do
    odd = Source.new(content_text: "Some Unit | Docket Number: 05099999 | Reactor Vendor/Type: Acme Reactors Type 9")
    assert_empty plugin.extract(odd, nil)

    Facility.create!(name: "Arkansas Nuclear One, Unit 1", nrc_docket: "05000313", facility_type: "power_reactor").verify!(by: "human:test")
    DataQuality::Pipeline.run("nrc_reactor_vendors", plugin:, only: %w[crawl extract match])
    link = page("ano1").candidates.find_by!(kind: "facility_relationship")
    assert_empty DataQuality::Review.approve(page("ano1").candidates.order(:id).pluck(:id), by: "human:test").flat_map(&:errors)
    stub_request(:get, "#{UNITS}ano1").to_return(body: file_fixture("nrc/units/ano1.html").read.sub("Babcock &amp; Wilcox", "Acme"))
    Source.update_all(fetched_at: 2.days.ago)
    crawl

    assert page("ano1").crawl_needs_human?
    assert page("ano1").candidates.where(review_origin: "dropped", subject_id: link.reload.subject_id).exists?
  end

  test "a same-day rerun after a block requests no later page" do
    stub_request(:get, /\A#{Regexp.escape(UNITS)}/).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)
    crawl

    assert_equal "unit page blocked", crawl.stats["stopped"]
    assert_requested :get, /\A#{Regexp.escape(UNITS)}/, times: 1
  end
end
