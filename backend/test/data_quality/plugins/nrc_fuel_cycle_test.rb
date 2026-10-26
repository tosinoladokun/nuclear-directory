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

  test "a page with no status line (a licence application, as Global Laser Enrichment's) is read as not operational" do
    stub_request(:get, %r{facility-finder/fc/}).to_return(body: file_fixture("nrc/fuel_cycle/urenco.html").read.sub(%r{<br><strong>Facility Status:</strong> Operational}, ""))
    crawl

    assert page.crawl_ok?
    assert_equal %w[facility organization], plugin.extract(page, nil).map { |c| c[:kind] }, "no operates link or stage without a status"
  end

  test "a page missing its docket is a changed layout and goes to a person" do
    stub_request(:get, %r{facility-finder/fc/}).to_return(body: file_fixture("nrc/fuel_cycle/urenco.html").read.sub(%r{<strong>Docket Number:</strong> 07003103<br>}, ""))

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

  test "a published facility that disappears, returns unchanged and disappears again is flagged both times" do
    DataQuality::Pipeline.run("nrc_fuel_cycle", plugin:, only: %w[crawl extract match])
    Facility.where(nrc_docket: "07003103").update_all(verification_status: "pending")
    approved = DataQuality::Review.approve(page.candidates.where(kind: "facility").pluck(:id), by: "human:test")
    assert approved.all?(&:ok?), approved.flat_map(&:errors).inspect

    gone = file_fixture("nrc/fuel_cycle/list.html").read.gsub("urenco-enrichment-fac-nm-lc", "gone")
    flags = -> { page.candidates.where(review_origin: "dropped").count }
    cycle = lambda do |list|
      stub_request(:get, Plugin::LIST_URL).to_return(body: list)
      Source.update_all(fetched_at: 2.days.ago)
      DataQuality::Pipeline.run("nrc_fuel_cycle", plugin:, only: %w[crawl extract match])
    end

    cycle.(gone)
    assert_equal 1, flags.call
    page.candidates.where(review_origin: "dropped").update_all(status: "merged")
    cycle.(file_fixture("nrc/fuel_cycle/list.html").read)
    cycle.(gone)
    assert_equal 2, flags.call, "flagged again after it returned"
  end

  test "a page removed between crawl and extract isn't read while it's unlisted" do
    crawl
    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/fuel_cycle/list.html").read.gsub("urenco-enrichment-fac-nm-lc", "gone"))
    Source.where(url: Plugin::LIST_URL).update_all(fetched_at: 2.days.ago)
    crawl

    DataQuality::Pipeline.run("nrc_fuel_cycle", plugin:, only: "extract")
    assert page.crawl_needs_human?
    assert_empty page.candidates
  end

  test "a failed read on return keeps the withdrawn claims waiting" do
    DataQuality::Pipeline.run("nrc_fuel_cycle", plugin:, only: %w[crawl extract match])
    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/fuel_cycle/list.html").read.gsub("urenco-enrichment-fac-nm-lc", "gone"))
    Source.update_all(fetched_at: 2.days.ago)
    crawl

    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/fuel_cycle/list.html").read)
    stub_request(:get, %r{facility-finder/fc/}).to_return(status: 500, body: "oops")
    Source.update_all(fetched_at: 2.days.ago)
    assert_nil crawl.stats["restored"]
    assert page.candidates.where(review_origin: "withdrawn").exists?
  end

  test "taking over a hand-cited page: its copy is dropped, and it's fetched afresh on the next permitted day" do
    Source.create!(url: URENCO, source_kind: "web_page", crawl_status: "ok", content_text: "<html>whole page</html>", content_sha256: "old",
      fetched_at: Time.current)

    crawl
    assert_nil page.content_text, "fetched today already: not again, and the whole page isn't kept"
    assert_not_requested :get, URENCO
    Source.update_all(fetched_at: 2.days.ago)
    crawl
    assert_equal LINE, page.content_text
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
