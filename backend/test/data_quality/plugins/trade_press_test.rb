require "test_helper"

# The fixture is World Nuclear News's real feed, fetched 2026-10-22 with the
# plug-in's user agent and cut to its first 8 items.
class DataQuality::Plugins::TradePressTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::TradePress
  FEED = "https://www.world-nuclear-news.org/rss".freeze
  TODAY = Date.new(2026, 10, 22)

  setup do
    stub_request(:get, "https://www.world-nuclear-news.org/robots.txt").to_return(status: 404)
    stub_request(:get, FEED).to_return(body: file_fixture("trade_press/wnn.xml").read, headers: { "Content-Type" => "application/rss+xml" })
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: { "World Nuclear News" => FEED }, today: -> { TODAY })
  def source = Source.find_by!(url: FEED)

  test "is the plug-in for trade_press, reading WNN and ANS" do
    assert_instance_of Plugin, DataQuality::Plugin.for("trade_press")
    assert_equal [ "World Nuclear News", "ANS Nuclear Newswire" ], Plugin::FEEDS.keys
  end

  test "each recent item is a lead: a news item about no one yet, marked lead" do
    DataQuality::Stages::Crawl.call(plugin:)
    candidates = plugin.extract(source, nil)

    assert_equal 8, candidates.size, "all 8 are within #{Plugin::WINDOW_DAYS} days"
    assert candidates.all? { |c| c[:payload]["lead"] == true && c[:payload]["about"] == [] && c[:payload]["publisher"] == "World Nuclear News" }
    assert candidates.all? { |c| plugin.quote_in_source?(source, c[:quote]) }
    assert_match "lead to the primary source", plugin.source_facts(source)
  end

  test "a lead is Data Quality's: held, refused if approved, listed but never counted" do
    DataQuality::Pipeline.run("trade_press", plugin:, only: %w[crawl extract match])
    lead = Candidate.where(kind: "news_item").first

    assert lead.status_needs_review?
    assert_match DataQuality::Review::LEAD, lead.notes
    assert_equal DataQuality::Review::LEAD, DataQuality::Review.held_reason(lead)
    assert_equal 0, DataQuality::Review.check_counts["all"], "not in the admin's counts"

    result = DataQuality::Review.approve([ lead.id ], by: "human:tosin").sole
    assert_equal [ DataQuality::Review::LEAD ], result.errors
    result = DataQuality::Review.approve([ lead.id ], by: "human:dq", data_quality_reviewed: true).sole
    assert_equal [ DataQuality::Review::LEAD ], result.errors, "a recommendation doesn't lift it"
    assert_empty NewsItem.all
  end
end
