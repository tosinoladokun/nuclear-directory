require "test_helper"

# The fixture is NASA's real news feed searched for fission surface power
# (10 items), fetched 2026-10-26 with the plug-in's user agent.
class DataQuality::Plugins::NasaNuclearNewsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NasaNuclearNews
  FEED = Plugin::FEEDS.values.first
  TODAY = Date.new(2026, 10, 26)

  setup do
    stub_request(:get, "https://www.nasa.gov/robots.txt").to_return(body: "User-agent: *\nAllow: /\n")
    stub_request(:get, FEED).to_return(body: file_fixture("nasa/search.xml").read, headers: { "Content-Type" => "application/rss+xml" })
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY })
  def source = Source.find_by!(url: FEED)

  test "is the plug-in for nasa_nuclear_news, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nasa_nuclear_news")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "nasa_nuclear_news"
  end

  test "only items about nuclear work: news about NASA, never a lead" do
    DataQuality::Stages::Crawl.call(plugin:)
    claims = plugin.extract(source, nil)

    assert_includes claims.map { |c| c[:quote] }, "NASA’s SR-1 Freedom Advances with Progress on Nuclear Power Module"
    refute_includes claims.map { |c| c[:quote] }, "NASA Welcomes Uzbekistan as Newest Artemis Accords Signatory"
    assert claims.all? { |c| c[:payload]["about"].first == { "name" => "NASA", "type" => "organization" } && !c[:payload].key?("lead") }
    assert claims.all? { |c| plugin.quote_in_source?(source, c[:quote]) }
  end

  test "a story that only mentions a nuclear-powered rover isn't nuclear news (PM, 15 Nov)" do
    mars = "<item><title>Perseverance instruments study Mars's ancient rock record</title><link>https://www.nasa.gov/mars-rock</link>" \
      "<pubDate>Mon, 26 Oct 2026 12:00:00 +0000</pubDate><description><![CDATA[<p>The nuclear-powered rover, kept warm by its radioisotope " \
      "power, studied layered rocks.</p>]]></description></item>"
    rtg = "<item><title>NASA tests a new radioisotope power system</title><link>https://www.nasa.gov/rtg</link>" \
      "<pubDate>Mon, 26 Oct 2026 12:00:00 +0000</pubDate><description><![CDATA[<p>A test of the next RTG.</p>]]></description></item>"
    stub_request(:get, FEED).to_return(body: file_fixture("nasa/search.xml").read.sub("<item>", "#{mars}#{rtg}<item>"), headers: { "Content-Type" => "application/rss+xml" })
    DataQuality::Stages::Crawl.call(plugin:)
    quotes = plugin.extract(source, nil).map { |c| c[:quote] }
    refute_includes quotes, "Perseverance instruments study Mars's ancient rock record"
    assert_includes quotes, "NASA tests a new radioisotope power system"
  end
end
