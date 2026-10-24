require "test_helper"

# Fixtures: NRC's real "Locations of Fuel Cycle Facilities" page and the
# URENCO USA facility page (fetched 2026-10-22 with the plug-in's user
# agent), the facility page cut to its facts.
class DataQuality::Plugins::NrcFuelCycleTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcFuelCycle
  URENCO = "https://www.nrc.gov/facilities-safety/facility-finder/fc/urenco-enrichment-fac-nm-lc".freeze
  LINE = "Louisiana Energy Services (LES) | Location: Eunice, NM | Licensee: URENCO–USA | Docket Number: 07003103 | " \
    "Facility Type: Uranium Enrichment – Gas Centrifuge | Facility Status: Operational".freeze

  setup do
    stub_request(:get, "https://www.nrc.gov/robots.txt").to_return(body: file_fixture("nrc/robots.txt").read)
    @list = stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/fuel_cycle/list.html").read)
    @pages = stub_request(:get, %r{\Ahttps://www\.nrc\.gov/facilities-safety/facility-finder/fc/}).to_return do |request|
      if request.uri.path.end_with?("/urenco-enrichment-fac-nm-lc")
        { body: file_fixture("nrc/fuel_cycle/urenco.html").read }
      else
        { body: "<html><main><h1>Closed Fuel Plant</h1><p><strong>Location:</strong> Erwin, TN<br><strong>Licensee:</strong> Old Fuel Co.<br>" \
          "<strong>Docket Number:</strong> 07000143<br><strong>Facility Type:</strong> Fuel Fabrication Facility<br>" \
          "<strong>Facility Status:</strong> Decommissioning</p></main></html>" }
      end
    end
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def page = Source.find_by!(url: URENCO)

  test "is the plug-in for nrc_fuel_cycle" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_fuel_cycle")
  end

  test "reads the locations page, then each facility page once a day, storing only its facts" do
    run = crawl
    second = crawl

    assert_equal "changed", run.stats["list"]
    assert_equal({ "changed" => 12 }, run.stats["facility_pages"])
    assert_equal({ "skipped_recent" => 12 }, second.stats["facility_pages"])
    assert_requested @list, times: 1
    assert_equal LINE, page.content_text
  end

  test "a blocked facility page stops the crawl" do
    stub_request(:get, %r{facility-finder/fc/}).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)

    assert_equal "facility page blocked", crawl.stats["stopped"]
  end

  test "a same-day rerun after a block requests no later page" do
    stub_request(:get, %r{facility-finder/fc/}).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)
    crawl

    assert_equal "facility page blocked", crawl.stats["stopped"]
    assert_requested :get, %r{facility-finder/fc/}, times: 1
  end

  test "a page missing its status is a changed layout, not a plant that stopped" do
    stub_request(:get, %r{facility-finder/fc/}).to_return(body: file_fixture("nrc/fuel_cycle/urenco.html").read.sub(%r{<br><strong>Facility Status:</strong> Operational}, ""))

    assert_equal 12, crawl.stats["facility_pages"]["needs_human"]
  end

  test "a facility the locations page stops linking: its waiting claims go to review, and return when it's linked again" do
    DataQuality::Pipeline.run("nrc_fuel_cycle", plugin:, only: %w[crawl extract match])
    waiting = page.candidates.where(status: %w[new matched needs_review]).count
    assert waiting.positive?

    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/fuel_cycle/list.html").read.gsub("urenco-enrichment-fac-nm-lc", "gone"))
    Source.update_all(fetched_at: 2.days.ago)
    assert_equal waiting, crawl.stats["withdrawn"]
    assert page.candidates.where(status: %w[new matched]).none?
    assert_match Plugin::UNLISTED, page.candidates.first.notes

    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/fuel_cycle/list.html").read)
    Source.update_all(fetched_at: 2.days.ago)
    assert_equal waiting, crawl.stats["restored"]
  end

  test "a facility page without its facts needs a person" do
    stub_request(:get, %r{facility-finder/fc/}).to_return(body: "<html><main><h1>Moved</h1></main></html>")

    assert_equal 12, crawl.stats["facility_pages"]["needs_human"]
    assert page.crawl_needs_human?
  end

  test "an operational plant: the facility, its licensee, an operates link and the stage its type states" do
    crawl
    claims = plugin.extract(page, nil)

    assert_equal [
      { kind: "facility", quote: LINE, payload: { "name" => "Louisiana Energy Services (LES)", "facility_type" => "enrichment",
        "nrc_docket" => "07003103", "country_code" => "US", "city" => "Eunice", "state" => "NM" } },
      { kind: "organization", quote: LINE, payload: { "name" => "URENCO–USA" } },
      { kind: "facility_relationship", quote: LINE, payload: { "organization" => { "name" => "URENCO–USA" },
        "facility" => { "name" => "Louisiana Energy Services (LES)", "nrc_docket" => "07003103" }, "relationship_type" => "operates" } },
      { kind: "organization_role", quote: LINE, payload: { "organization" => { "name" => "URENCO–USA" }, "role" => "enrichment" } }
    ], claims
    assert plugin.quote_in_source?(page, LINE)
  end

  test "a plant that isn't operational: the facility and its licensee only" do
    crawl
    other = Source.where(source_kind: "nrc_fuel_cycle").where.not(url: URENCO).first
    kinds = plugin.extract(other, nil).map { |c| c[:kind] }

    assert_equal %w[facility organization], kinds
    assert_equal "fuel_facility", plugin.extract(other, nil).first[:payload]["facility_type"]
  end
end
