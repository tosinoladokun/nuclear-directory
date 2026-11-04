require "test_helper"

# The fixture is PR Newswire's real energy feed (20 items), fetched 2026-11-03
# with the plug-in's user agent; a nuclear item naming a company is added for the test.
class DataQuality::Plugins::WirePressTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::WirePress
  FEED = Plugin::FEEDS["PR Newswire (energy)"]
  TODAY = Date.new(2026, 11, 3)
  NUCLEAR_ITEM = "<item><title>Duke Energy Files to Extend Nuclear Plant Licenses</title><link>https://www.prnewswire.com/news-releases/duke-nuclear-1.html</link>" \
    "<pubDate>Tue, 3 Nov 2026 12:00:00 +0000</pubDate><description><![CDATA[<p>Duke Energy asked the NRC to extend its reactor licenses.</p>]]></description></item>"

  setup do
    stub_request(:get, "https://www.prnewswire.com/robots.txt").to_return(status: 404)
    xml = file_fixture("wire/prn_energy.xml").read.sub("<item>", "#{NUCLEAR_ITEM}<item>")
    @feed = stub_request(:get, FEED).to_return(body: xml, headers: { "Content-Type" => "application/xml" })
    duke = Organization.create!(name: "Duke Energy")
    duke.aliases.find_or_create_by!(alias: "Duke Energy")
    duke.verify!(by: "human:tosin")
  end

  def plugin(now: Time.zone.local(2026, 11, 3, 13)) = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: { "PR Newswire (energy)" => FEED },
    today: -> { TODAY }, now: -> { now })
  def source = Source.find_by!(url: FEED)

  test "is the plug-in for wire_press, read every 3 hours by its own job" do
    assert_instance_of Plugin, DataQuality::Plugin.for("wire_press")
    assert_match "wire_press", Rails.root.join("config/recurring.yml").read
  end

  test "reads at most every 3 hours and keeps earlier items when the feed moves on" do
    assert_equal({ "PR Newswire (energy)" => "changed" }, DataQuality::Stages::Crawl.call(plugin:).stats)
    assert_equal({ "PR Newswire (energy)" => "skipped_recent" }, DataQuality::Stages::Crawl.call(plugin: plugin(now: Time.zone.local(2026, 11, 3, 15))).stats)

    stub_request(:get, FEED).to_return(body: file_fixture("wire/prn_energy.xml").read, headers: { "Content-Type" => "application/xml" })
    DataQuality::Stages::Crawl.call(plugin: plugin(now: Time.zone.local(2026, 11, 3, 17)))
    assert_includes source.content_text, "Duke Energy Files to Extend Nuclear Plant Licenses", "kept after it left the feed"
  end

  test "only nuclear items naming a company we have become news, never leads" do
    DataQuality::Stages::Crawl.call(plugin:)
    claims = plugin.extract(source, nil)

    assert_equal [ "Duke Energy Files to Extend Nuclear Plant Licenses" ], claims.map { |c| c[:quote] }
    payload = claims.sole[:payload]
    assert_equal "PR Newswire", payload["publisher"]
    assert_equal [ "Duke Energy" ], payload["about"].map { |a| a["name"] }
    refute payload.key?("lead")
    assert plugin.quote_in_source?(source, claims.sole[:quote])
  end

  test "only strong nuclear words count on the wire" do
    assert_match Plugin::STRONG_NUCLEAR, "Duke Energy Files to Extend Nuclear Plant Licenses"
    refute_match Plugin::STRONG_NUCLEAR, "Oracle Adds Data Enrichment to Its Repository; Plasma Screens for Duke Energy"
    refute_match Plugin::STRONG_NUCLEAR, "Duke Energy Completes Decommissioning of Coal Plant"
  end

  test "a release both feeds carry is proposed once; TVA counts as a name; stored order is stable" do
    tva = Organization.create!(name: "Tennessee Valley Authority")
    tva.aliases.find_or_create_by!(alias: "TVA")
    tva.verify!(by: "human:tosin")
    item = "<item><title>TVA Picks Site for New Reactor</title><link>https://www.prnewswire.com/news-releases/tva-1.html</link>" \
      "<pubDate>Tue, 3 Nov 2026 09:00:00 +0000</pubDate></item>"
    both = { "PR Newswire (energy)" => FEED, "PR Newswire (utilities)" => Plugin::FEEDS["PR Newswire (utilities)"] }
    rss = "<?xml version='1.0'?><rss version='2.0'><channel><title>x</title>#{item}</channel></rss>"
    both.each_value { |url| stub_request(:get, url).to_return(body: rss, headers: { "Content-Type" => "application/xml" }) }
    p = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: both, today: -> { TODAY }, now: -> { Time.zone.local(2026, 11, 3, 13) })
    DataQuality::Stages::Crawl.call(plugin: p)
    DataQuality::Stages::Extract.call(plugin: p)

    claims = Candidate.where(kind: "news_item")
    assert_equal 1, claims.count, "one release, one claim"
    assert_equal [ "TVA" ], claims.sole.payload["about"].map { |a| a["name"] }
  end

  test "an on-time read three hours later isn't skipped" do
    DataQuality::Stages::Crawl.call(plugin:)
    assert_equal({ "PR Newswire (energy)" => "unchanged" }, DataQuality::Stages::Crawl.call(plugin: plugin(now: Time.zone.local(2026, 11, 3, 16))).stats)
  end
end
