require "test_helper"

# Fixtures: NRC's real non-power reactor locations page and two real
# reactor pages, MIT's and Texas A&M's TRIGA (fetched 2026-10-26 with the
# plug-in's user agent, cut to their facts table). The other reactors are
# written in the same layout: a title naming the licensee, then a table of
# label and value cells.
class DataQuality::Plugins::NrcResearchReactorsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcResearchReactors
  PAGES = %r{\Ahttps://www\.nrc\.gov/facilities-safety/facility-finder/nonpower/}
  MIT = "https://www.nrc.gov/facilities-safety/facility-finder/nonpower/mit-ma-hwr-reflected".freeze

  setup do
    stub_request(:get, "https://www.nrc.gov/robots.txt").to_return(body: file_fixture("nrc/robots.txt").read)
    @list = stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/nonpower/list.html").read)
    @pages = stub_request(:get, PAGES).to_return do |request|
      slug = request.uri.path.split("/").last
      real = Rails.root.join("test/fixtures/files/nrc/nonpower/#{{ "mit-ma-hwr-reflected" => "mit", "tamu-tx-triga" => "tamu" }[slug]}.html")
      next { body: real.read } if %w[mit-ma-hwr-reflected tamu-tx-triga].include?(slug)

      { body: "<html><main><h1>Licensee of #{slug}</h1><table><tr><td><strong>Location:</strong></td><td>Springfield, IL</td></tr>" \
        "<tr><td><strong>Docket Number:</strong></td><td>0500#{slug.sum.to_s.rjust(4, '0')}</td></tr>" \
        "<tr><td><strong>Reactor Type:</strong></td><td>TRIGA</td></tr><tr><td><strong>Power Level (kW):</strong></td><td>1,000</td></tr></table>" \
        "<p>Project Manager: (a person)</p></main></html>" }
    end
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def mit = Source.find_by!(url: MIT)

  test "is the plug-in for nrc_research_reactors" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_research_reactors")
  end

  test "reads the research and test reactor table, then each reactor page once a day; not the medical or advanced tables" do
    run = crawl
    second = crawl

    assert_equal 29, run.stats["reactors"]
    assert_equal({ "changed" => 29 }, run.stats["reactor_pages"])
    assert_equal({ "skipped_recent" => 29 }, second.stats["reactor_pages"])
    assert_not_requested :get, %r{nonpower/shine-medical}
    assert_equal "Massachusetts Institute of Technology HWR Reflected reactor | Licensee: Massachusetts Institute of Technology | " \
      "Location: Cambridge, MA | Docket Number: 05000020 | Reactor Type: HWR Reflected", mit.content_text
    refute_match(/Project Manager|Power Level|R-37/, mit.content_text)
  end

  test "a same-day rerun after a block requests no later page" do
    stub_request(:get, PAGES).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)
    first = crawl
    second = crawl

    assert_equal "reactor page blocked", first.stats["stopped"]
    assert_equal "reactor page blocked", second.stats["stopped"]
    assert_requested :get, PAGES, times: 1 # the first run's blocked page; the rerun asks for none
  end

  test "the licensee is the page's title, not the table's Name column, and the reactor type tells Texas A&M's two apart" do
    crawl
    tamu = Source.find_by!(url: "https://www.nrc.gov/facilities-safety/facility-finder/nonpower/tamu-tx-triga")
    facility, organization = plugin.extract(tamu, nil)
    assert_equal "Texas A&M University", organization[:payload]["name"]
    assert_equal [ "Texas A&M University TRIGA reactor", "05000128" ], facility[:payload].values_at("name", "nrc_docket")
  end

  test "a table row without its page link makes the whole read unusable; nothing is withdrawn" do
    DataQuality::Pipeline.run("nrc_research_reactors", plugin:, only: %w[crawl extract match])
    broken = file_fixture("nrc/nonpower/list.html").read.sub(%r{<a href="/facilities-safety/facility-finder/nonpower/mit-ma-hwr-reflected">(.*?)</a>}, '\\1')
    stub_request(:get, Plugin::LIST_URL).to_return(body: broken)
    Source.update_all(fetched_at: 2.days.ago)

    stats = crawl.stats
    assert_equal 0, stats["reactors"]
    assert_nil stats["withdrawn"]
    assert Source.find_by!(url: Plugin::LIST_URL).crawl_needs_human?
  end

  test "a page removed between crawl and extract isn't read while it's unlisted" do
    crawl
    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/nonpower/list.html").read.gsub("mit-ma-hwr-reflected", "gone"))
    stub_request(:get, PAGES).to_return(status: 404)
    Source.where(url: Plugin::LIST_URL).update_all(fetched_at: 2.days.ago)
    crawl
    DataQuality::Pipeline.run("nrc_research_reactors", plugin:, only: "extract")

    assert mit.crawl_needs_human?
    assert_empty mit.candidates
  end

  test "a reactor the table stops linking: its waiting claims go to review" do
    DataQuality::Pipeline.run("nrc_research_reactors", plugin:, only: %w[crawl extract match])
    waiting = mit.candidates.where(status: %w[new matched needs_review]).count
    stub_request(:get, Plugin::LIST_URL).to_return(body: file_fixture("nrc/nonpower/list.html").read.gsub("mit-ma-hwr-reflected", "gone"))
    stub_request(:get, PAGES).to_return(status: 404)
    Source.update_all(fetched_at: 2.days.ago)

    assert_equal waiting, crawl.stats["withdrawn"]
    assert_match Plugin::UNLISTED, mit.candidates.first.notes
  end

  test "a blocked reactor page stops the crawl; a page without a docket needs a person" do
    stub_request(:get, PAGES).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)
    assert_equal "reactor page blocked", crawl.stats["stopped"]

    Source.update_all(fetched_at: 2.days.ago, blocked_streak: 0, crawl_status: "ok")
    stub_request(:get, PAGES).to_return(body: "<html><main><h1>Moved</h1></main></html>")
    assert_equal 29, crawl.stats["reactor_pages"]["needs_human"]
  end

  test "the reactor, its licensee, and university only where the licensee's name says so" do
    crawl
    claims = plugin.extract(mit, nil)

    assert_equal %w[facility organization organization_role], claims.map { |c| c[:kind] }
    assert_equal({ "name" => "Massachusetts Institute of Technology HWR Reflected reactor", "facility_type" => "research_reactor", "nrc_docket" => "05000020",
      "country_code" => "US", "city" => "Cambridge", "state" => "MA" }, claims.first[:payload])
    assert_equal "university", claims.last[:payload]["role"]
    dow = Source.find_by!(url: "https://www.nrc.gov/facilities-safety/facility-finder/nonpower/dcc-mi-triga")
    assert_equal %w[facility organization], plugin.extract(dow, nil).map { |c| c[:kind] }, "a company gets no role from its name"
  end
end
