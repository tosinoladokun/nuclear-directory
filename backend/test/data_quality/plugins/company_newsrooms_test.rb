require "test_helper"

# The fixture is Cameco's real news feed, fetched 2026-10-22 with the
# plug-in's user agent.
class DataQuality::Plugins::CompanyNewsroomsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::CompanyNewsrooms
  FEED = "https://www.cameco.com/rss/news".freeze
  FEEDS = { "Cameco" => FEED }.freeze
  TODAY = Date.new(2026, 10, 22)

  setup do
    stub_request(:get, "https://www.cameco.com/robots.txt").to_return(body: "User-agent: *\nDisallow: /admin/\n")
    @feed = stub_request(:get, FEED).to_return(body: xml, headers: { "Content-Type" => "application/rss+xml" })
  end

  def xml = file_fixture("newsrooms/cameco.xml").read
  def plugin(feeds: FEEDS) = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds:, today: -> { TODAY })
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def stored(content = xml) = Source.create!(url: FEED, source_kind: "company_newsrooms", crawl_status: "ok",
    content_text: content, content_sha256: Digest::SHA256.hexdigest(content))

  test "is the plug-in for company_newsrooms, and runs daily" do
    assert_instance_of Plugin, DataQuality::Plugin.for("company_newsrooms")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "company_newsrooms"
  end

  test "crawls each feed once a day" do
    assert_equal({ "Cameco" => "changed" }, crawl.stats)
    assert_equal({ "Cameco" => "skipped_recent" }, crawl.stats)
    assert_requested @feed, times: 1
  end

  test "a blocked feed is recorded, never worked around" do
    stub_request(:get, FEED).to_return(status: 403, body: "Forbidden")

    assert_equal({ "Cameco" => "blocked" }, crawl.stats)
    assert Source.find_by!(url: FEED).crawl_blocked?
  end

  test "a page that isn't a feed needs a human, and extracts nothing" do
    stub_request(:get, FEED).to_return(body: "<html><body><p>Our newsroom moved.</p></body></html>", headers: { "Content-Type" => "text/html" })

    assert_equal({ "Cameco" => "not_a_feed" }, crawl.stats)
    source = Source.find_by!(url: FEED)
    assert source.crawl_needs_human?
    assert_empty plugin.extract(source, nil)
  end

  test "each recent item is a news item about the company, quoting its title" do
    source = stored
    candidates = plugin.extract(source, nil)

    assert candidates.any?
    assert candidates.all? { |c| c[:kind] == "news_item" && plugin.quote_in_source?(source, c[:quote]) }
    assert candidates.all? { |c| Date.parse(c[:payload]["published_on"]) >= TODAY - Plugin::WINDOW_DAYS }, "only the last #{Plugin::WINDOW_DAYS} days"
    first = candidates.find { |c| c[:quote] == "Cameco Provides Date for 2026 Q3 Results, Conference Call and Webcast" }
    assert_equal({ "url" => "https://www.cameco.com/media/news/cameco-provides-date-for-2026-q3-results-conference-call-and-webcast",
      "title" => "Cameco Provides Date for 2026 Q3 Results, Conference Call and Webcast", "publisher" => "Cameco", "published_on" => "2026-10-20",
      "about" => [ { "name" => "Cameco", "type" => "organization" } ] }, first[:payload].except("summary"))
    assert first[:payload]["summary"].length <= Plugin::SUMMARY_LENGTH
    refute_match(/</, first[:payload]["summary"], "the summary is plain text")
    assert_match "Cameco Provides Date", plugin.verification_context(source, first[:quote])
    assert_match "Cameco's own news feed", plugin.source_facts(source)
  end

  test "an Atom feed reads the same way" do
    atom = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom"><title>News</title>
        <entry><title>Acme signs a fuel deal</title><link rel="alternate" href="https://acme.example/news/fuel"/>
          <published>2026-10-01T12:00:00Z</published><summary>&lt;p&gt;Acme &amp; a utility agreed.&lt;/p&gt;</summary></entry>
        <entry><title>Old news</title><link href="https://acme.example/news/old"/><updated>2025-01-01T00:00:00Z</updated></entry>
      </feed>
    XML
    source = Source.create!(url: "https://acme.example/feed", source_kind: "company_newsrooms", crawl_status: "ok", content_text: atom, content_sha256: "x")

    candidates = plugin(feeds: { "Acme" => source.url }).extract(source, nil)

    assert_equal [ { kind: "news_item", quote: "Acme signs a fuel deal", payload: { "url" => "https://acme.example/news/fuel", "title" => "Acme signs a fuel deal",
      "publisher" => "Acme", "published_on" => "2026-10-01", "summary" => "Acme & a utility agreed.", "about" => [ { "name" => "Acme", "type" => "organization" } ] } } ], candidates
  end

  test "a feed's items leaving it drop nothing, and only its items count as a change" do
    source = stored
    assert_equal 0.0, plugin.max_dropped_share(source)
    rebuilt = xml.sub("<channel>", "<channel><lastBuildDate>Thu, 22 Oct 2026 00:00:00 +0000</lastBuildDate>")
    assert_equal plugin.rows_sha256(source), plugin.rows_sha256(Source.new(content_text: rebuilt))
  end
end
