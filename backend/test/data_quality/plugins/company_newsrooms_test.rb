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
    first = candidates.find { |c| c[:payload]["published_on"] == "2026-09-22" }
    assert_equal({ "url" => "https://www.cameco.com/media/news/cameco-acknowledges-united-states-and-republic-of-korea-announcement-of-framework-for",
      "publisher" => "Cameco", "published_on" => "2026-09-22", "about" => [ { "name" => "Cameco", "type" => "organization" } ] },
      first[:payload].except("summary", "title"))
    assert_match "Framework for the Deployment of Nuclear Power", first[:payload]["title"]
    refute candidates.any? { |c| c[:quote].start_with?("Cameco Provides Date") }, "a results date isn't nuclear news (DQ, 29 Oct)"
    assert candidates.none? { |c| c[:payload].key?("summary") }, "Cameco repeats one release's text under every item: no summaries"
    assert_match "Republic of Korea", plugin.verification_context(source, first[:quote])
    assert_match "Cameco's own news feed", plugin.source_facts(source)
  end

  test "a release names its partners by legal form: they join what it's about, so the ones we don't have become leads" do
    atom = <<~XML
      <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry><title>Acme signs fuel supply deal with Bright Fuel Holdings, Inc. and Grid Co LLC</title><link href="https://acme.example/n"/>
          <published>2026-10-01T00:00:00Z</published><summary>Acme Fission, Inc. and its partners announced the deal.</summary></entry></feed>
    XML
    source = Source.create!(url: "https://acme.example/feed", source_kind: "company_newsrooms", crawl_status: "ok", content_text: atom, content_sha256: "x")

    about = plugin(feeds: { "Acme" => source.url }).extract(source, nil).sole[:payload]["about"].map { |a| a["name"] }

    assert_equal [ "Acme", "Bright Fuel Holdings, Inc", "Grid Co LLC" ], about
  end

  test "a Title Case headline: the partner's name starts after the last joining word" do
    atom = <<~XML
      <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry><title>Acme Signs Uranium Agreement With Bright Fuel Holdings, Inc.</title><link href="https://acme.example/a"/><published>2026-10-01T00:00:00Z</published></entry>
        <entry><title>Signs Deal With Grid Power LLC And Selects Nova Reactors Corp</title><link href="https://acme.example/b"/><published>2026-10-02T00:00:00Z</published></entry></feed>
    XML
    source = Source.create!(url: "https://acme.example/feed", source_kind: "company_newsrooms", crawl_status: "ok", content_text: atom, content_sha256: "x")

    abouts = plugin(feeds: { "Acme" => source.url }).extract(source, nil).to_h { |c| [ c[:quote], c[:payload]["about"].map { |a| a["name"] } ] }

    assert_equal [ "Acme", "Bright Fuel Holdings, Inc" ], abouts["Acme Signs Uranium Agreement With Bright Fuel Holdings, Inc."]
    assert_equal [ "Acme", "Grid Power LLC", "Nova Reactors Corp" ], abouts["Signs Deal With Grid Power LLC And Selects Nova Reactors Corp"]
  end

  test "an Atom feed reads the same way" do
    atom = <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <feed xmlns="http://www.w3.org/2005/Atom"><title>News</title>
        <entry><title>Acme signs a nuclear fuel deal</title><link rel="alternate" href="https://acme.example/news/fuel"/>
          <published>2026-10-01T12:00:00Z</published><summary>&lt;p&gt;Acme &amp; a utility agreed.&lt;/p&gt;</summary></entry>
        <entry><title>Old news</title><link href="https://acme.example/news/old"/><updated>2025-01-01T00:00:00Z</updated></entry>
      </feed>
    XML
    source = Source.create!(url: "https://acme.example/feed", source_kind: "company_newsrooms", crawl_status: "ok", content_text: atom, content_sha256: "x")

    candidates = plugin(feeds: { "Acme" => source.url }).extract(source, nil)

    assert_equal [ { kind: "news_item", quote: "Acme signs a nuclear fuel deal", payload: { "url" => "https://acme.example/news/fuel", "title" => "Acme signs a nuclear fuel deal",
      "publisher" => "Acme", "published_on" => "2026-10-01", "summary" => "Acme & a utility agreed.", "about" => [ { "name" => "Acme", "type" => "organization" } ] } } ], candidates
  end

  test "an item already matched or decided isn't proposed again when the feed changes" do
    source = stored
    url = "https://www.cameco.com/media/news/cameco-provides-date-for-2026-q3-results-conference-call-and-webcast"
    source.candidates.create!(kind: "news_item", status: "rejected", quote: "q", payload: { "url" => url })
    source.candidates.create!(kind: "news_item", status: "new", quote: "q", payload: { "url" => "https://www.cameco.com/other" })

    urls = plugin.extract(source, nil).map { |c| c[:payload]["url"] }
    refute_includes urls, url
    assert urls.any?
  end

  test "a feed that moved address doesn't propose items already claimed from its old one" do
    url = "https://www.cameco.com/media/news/cameco-provides-date-for-2026-q3-results-conference-call-and-webcast"
    old = Source.create!(url: "https://old.cameco.example/rss", source_kind: "company_newsrooms", crawl_status: "ok", content_text: "x", content_sha256: "x")
    old.candidates.create!(kind: "news_item", status: "rejected", quote: "q", payload: { "url" => url })

    refute_includes plugin.extract(stored, nil).map { |c| c[:payload]["url"] }, url
  end

  test "a summary changing is a change; a summary is plain text, cut at a word" do
    atom = ->(summary) { <<~XML }
      <?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
        <entry><title>Acme reactor news</title><link href="https://acme.example/n"/><published>2026-10-01T00:00:00Z</published><summary>#{summary}</summary></entry></feed>
    XML
    before = Source.new(content_text: atom.("&lt;b&gt;First&lt;/b&gt; text"))
    after = Source.new(content_text: atom.("Corrected text"))
    refute_equal plugin.rows_sha256(before), plugin.rows_sha256(after)
    long = Source.create!(url: "https://acme.example/feed", source_kind: "company_newsrooms", crawl_status: "ok", content_sha256: "x",
      content_text: atom.("word " * 200))
    summary = plugin(feeds: { "Acme" => long.url }).extract(long, nil).sole[:payload]["summary"]
    assert summary.length <= Plugin::SUMMARY_LENGTH
    assert_equal "First text", plugin.send(:items, before.content_text).sole.summary
  end

  test "a feed's items leaving it drop nothing, and only its items count as a change" do
    source = stored
    assert_equal 0.0, plugin.max_dropped_share(source)
    rebuilt = xml.sub("<channel>", "<channel><lastBuildDate>Thu, 22 Oct 2026 00:00:00 +0000</lastBuildDate>")
    assert_equal plugin.rows_sha256(source), plugin.rows_sha256(Source.new(content_text: rebuilt))
  end

  class Websites
    def initialize(list) = @list = list
    def organizations_with_website = @list
    def published_names = {}
    def organization(name:) = nil
  end

  def discovering(list)
    Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: FEEDS, today: -> { TODAY }, discover: true, directory: Websites.new(list))
  end

  test "finds a published company's feed from its homepage's own link, and reads it from then on" do
    stub_request(:get, "https://acmefission.com/robots.txt").to_return(status: 404)
    stub_request(:get, "https://acmefission.com/").to_return(body: <<~HTML)
      <html><head>
        <link rel="alternate" type="application/rss+xml" href="https://feeds.other.com/acme">
        <link rel="alternate" type="application/rss+xml" href="/comments/feed/">
        <link rel="alternate" type="application/rss+xml" href="/news/feed/">
      </head></html>
    HTML
    acme = stub_request(:get, "https://acmefission.com/news/feed/").to_return(body: xml, headers: { "Content-Type" => "application/rss+xml" })
    nothing = stub_request(:get, "https://plainco.com/").to_return(body: "<html><head></head></html>")
    stub_request(:get, "https://plainco.com/robots.txt").to_return(status: 404)
    plugin = discovering([ [ "Acme Fission", "acmefission.com" ], [ "Plain Co", "https://www.plainco.com/about" ] ])
    stub_request(:get, "https://www.plainco.com/robots.txt").to_return(status: 404)
    stub_request(:get, "https://www.plainco.com/").to_return(body: "<html><head></head></html>")

    stats = DataQuality::Stages::Crawl.call(plugin:).stats
    assert_equal 2, stats["homepages_read"]
    assert_equal 1, stats["feeds_found"]
    assert_equal "https://acmefission.com/news/feed/", plugin.feeds["Acme Fission"]
    assert_equal "changed", stats["Acme Fission"]
    assert_requested acme, times: 1
    assert_not_requested nothing
    assert_equal 5, plugin.new_sources_per_run

    source = Source.find_by!(url: "https://acmefission.com/news/feed/")
    claims = plugin.extract(source, nil)
    assert claims.all? { |claim| claim[:payload]["publisher"] == "Acme Fission" }
    assert_operator claims.size, :<=, Plugin::FIRST_READ_ITEMS, "a found feed's back catalogue: only its newest items"
    assert_equal claims.map { |c| c[:payload]["published_on"] }.sort.reverse, claims.map { |c| c[:payload]["published_on"] }
    assert_equal "Company: Acme Fission", Source.find_by!(url: "https://acmefission.com/#newsroom").content_text.lines.first.chomp
    assert_equal({ "homepages_read" => 0, "feeds_found" => 0 }, DataQuality::Stages::Crawl.call(plugin:).stats.slice("homepages_read", "feeds_found"))
  end

  test "at most DISCOVER_PER_NIGHT homepages a night; fixed-list and trade press plug-ins never discover" do
    stub_request(:get, /robots\.txt/).to_return(status: 404)
    stub_request(:get, %r{\Ahttps://co\d+\.com/\z}).to_return(body: "<html></html>")
    list = (1..12).map { |i| [ "Co #{i}", "co#{i}.com" ] }

    assert_equal Plugin::DISCOVER_PER_NIGHT, DataQuality::Stages::Crawl.call(plugin: discovering(list)).stats["homepages_read"]
    assert_nil plugin.new_sources_per_run
    refute_includes DataQuality::Plugins::TradePress.new.feeds.keys, "Co 1"
  end

  test "a found feed: everything since it was found, and only the newest three from before" do
    item = ->(day) { Plugin::Item.new(title: "Item #{day}", url: "https://x/#{day}", published_on: Date.new(2026, 10, day), summary: nil) }
    source = Source.new(created_at: Time.zone.local(2026, 10, 20))
    kept = discovering([]).send(:since_found, source, [ 1, 5, 10, 15, 18, 21, 22 ].map(&item))
    assert_equal [ 22, 21, 18, 15, 10 ], kept.map { |each| each.published_on.day }
  end

  test "a found feed names only partners the directory has; a listed feed names every legal-suffix partner" do
    known = Class.new(Websites) { def organization(name:) = (Object.new if name == "Known Fission, Inc") }.new([])
    found = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: FEEDS, today: -> { TODAY }, discover: true, directory: known)
    listed = plugin
    item = Plugin::Item.new(title: "Acme Signs With Known Fission, Inc and Stray Parts, LLC", url: "https://x/1", published_on: TODAY, summary: nil)

    assert_equal [ "Acme", "Known Fission, Inc" ], found.send(:about, "Acme", item, directory_only: true).map { |each| each["name"] }
    assert_equal [ "Acme", "Known Fission, Inc", "Stray Parts, LLC" ], listed.send(:about, "Acme", item).map { |each| each["name"] }
  end

  test "a homepage the directory already cites is read for its feed on a row of its own" do
    cited = Source.create!(url: "https://acmefission.com/", source_kind: "web_page", content_text: "evidence", crawl_status: "ok")
    stub_request(:get, "https://acmefission.com/robots.txt").to_return(status: 404)
    stub_request(:get, "https://acmefission.com/").to_return(body: '<html><head><link rel="alternate" type="application/rss+xml" href="/feed/"></head></html>')
    stub_request(:get, "https://acmefission.com/feed/").to_return(body: xml, headers: { "Content-Type" => "application/rss+xml" })

    assert_equal 1, DataQuality::Stages::Crawl.call(plugin: discovering([ [ "Acme Fission", "acmefission.com" ] ])).stats["homepages_read"]
    assert_equal [ "web_page", "evidence" ], cited.reload.values_at(:source_kind, :content_text)
  end

  test "only news about nuclear becomes a claim; a broad company's needs a nuclear word (29 Oct: Amazon Alexa)" do
    item = ->(title) { Plugin::Item.new(title:, url: "https://x/#{title.parameterize}", published_on: TODAY, summary: nil) }
    names = Class.new do
      def published_names = { "Organization" => [ "Kairos Power", "Constellation Energy Corporation" ] }
      def organization(name:) = { "Cloud Hall" => 1, "Acme Fission" => 2, "Constellation" => 3, "Constellation Energy Corporation" => 3, "Kairos Power" => 4 }[name]&.then { |id| Struct.new(:id).new(id) }
      def role_keys(id) = id == 1 ? %w[data_center_offtaker] : %w[reactor_vendor]
    end.new
    listed = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: FEEDS, today: -> { TODAY }, directory: names)

    refute listed.send(:about_nuclear?, "Cameco", item.("Cameco Provides Date for 2026 Q3 Results")), "listed feeds too: a date isn't news"
    assert listed.send(:about_nuclear?, "Cameco", item.("Cameco Signs Uranium Supply Agreement in Korea"))
    assert listed.send(:about_nuclear?, "Acme Fission", item.("Acme Signs Uranium Supply Deal"))
    assert listed.send(:about_nuclear?, "Acme Fission", item.("Acme Partners With Kairos Power")), "names a company we have"
    refute listed.send(:about_nuclear?, "Acme Fission", item.("Acme Names New Board Chair"))
    refute listed.send(:about_nuclear?, "Amazon", item.("Alexa Gets New Voices With Kairos Power Fans")), "broad: a nuclear word is required"
    assert listed.send(:about_nuclear?, "Amazon", item.("Amazon Invests In Small Modular Reactors And SMR Developer"))
    refute listed.send(:about_nuclear?, "Cloud Hall", item.("Cloud Hall Opens Campus With Kairos Power Fans")), "a data-center offtaker only: nuclear word needed"
    refute listed.send(:about_nuclear?, "Equinix", item.("Equinix Adds Kairos Power Hall")), "broad"
    refute listed.send(:about_nuclear?, "GE Vernova", item.("GE Vernova Wins Wind Order With Kairos Power")), "GE Vernova is broad"
    refute listed.send(:about_nuclear?, "Constellation", item.("Constellation Energy Corporation Names New Board Chair")), "its own legal-name alias isn't another record"
  end
end
