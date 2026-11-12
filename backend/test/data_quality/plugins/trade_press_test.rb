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

  test "is the plug-in for trade_press, reading WNN, ANS, NucNet and NEI magazine" do
    assert_instance_of Plugin, DataQuality::Plugin.for("trade_press")
    assert_equal [ "World Nuclear News", "ANS Nuclear Newswire", "NucNet", "Nuclear Engineering International" ], Plugin::FEEDS.keys
  end

  test "only an item naming a company or plant in the directory becomes a lead, about what it names" do
    DataQuality::Stages::Crawl.call(plugin:)
    assert_empty plugin.extract(source, nil), "nothing we have is named: no leads"

    Organization.create!(name: "Rolls-Royce SMR").verify!(by: "human:tosin")
    Facility.create!(name: "Akkuyu", facility_type: "power_reactor").verify!(by: "human:tosin")
    candidates = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: { "World Nuclear News" => FEED }, today: -> { TODAY }).extract(source, nil)

    assert_equal [ [ { "name" => "Akkuyu", "type" => "facility" } ], [ { "name" => "Rolls-Royce SMR", "type" => "organization" } ] ].sort_by(&:to_s),
      candidates.map { |c| c[:payload]["about"] }.sort_by(&:to_s)
    assert candidates.all? { |c| c[:payload]["lead"] == true && c[:payload]["publisher"] == "World Nuclear News" }
    assert candidates.all? { |c| plugin.quote_in_source?(source, c[:quote]) }
    assert_match "lead to the primary source", plugin.source_facts(source)
  end

  test "at most #{Plugin::PER_FEED} leads a feed a night, newest first" do
    Organization.create!(name: "Nuclear").verify!(by: "human:tosin")
    DataQuality::Stages::Crawl.call(plugin:)
    assert_operator plugin.extract(source, nil).size, :<=, Plugin::PER_FEED
  end

  test "a lead is Data Quality's: held, refused if approved, listed but never counted" do
    Organization.create!(name: "Rolls-Royce SMR").verify!(by: "human:tosin")
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
    result = DataQuality::Review.edit_and_approve(lead.id, attributes: { "lead" => "true", "title" => "Edited" }, by: "human:tosin")
    assert_equal [ DataQuality::Review::LEAD ], result.errors, "the form's lead field, sent back as text, changes nothing"
    assert_equal true, lead.reload.payload["lead"]
    assert_empty NewsItem.all
  end

  FakeLLM = Struct.new(:data, :asked) do
    def structured(messages:, **)
      asked << messages.last[:content]
      DataQuality::OpenRouter::Client::Response.new(data:, model: "fake", usage: {})
    end
  end

  test "the day's items naming nothing we have give their US companies as leads, in the item's own words (10 Nov)" do
    DataQuality::Stages::Crawl.call(plugin:)
    westinghouse = Organization.find_by(slug: "westinghouse") || Organization.create!(name: "Westinghouse")
    westinghouse.update_columns(verification_status: "verified", verified_by: "human:tosin")
    westinghouse.aliases.find_or_create_by!(alias: "Westinghouse")
    llm = FakeLLM.new({ "companies" => [ { "name" => "Hot Testing Co", "item" => 1 }, { "name" => "US DOE", "item" => 9 },
      { "name" => "Joint venture", "item" => 2 }, { "name" => "Joint venture", "item" => 0 }, { "name" => "US DOE", "item" => -1 } ] }, [])
    today = Date.new(2026, 10, 15)
    examined = ActiveSupport::Cache::MemoryStore.new
    reader = -> { Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: { "World Nuclear News" => FEED }, today: -> { today }, llm:, examined:) }
    reader.call.extract(source, nil)

    refute_includes llm.asked.sole, "Westinghouse places initial orders", "an item naming a company we have isn't asked about"
    assert_includes llm.asked.sole, "US DOE funding to accelerate molten salt reactor development"
    assert_equal [ "Joint venture" ], Lead.pluck(:name), "only a name in its own item's words (item 1 doesn't say Hot Testing Co; no item 9, 0 or -1)"

    reader.call.extract(source, nil)
    assert_equal 1, llm.asked.size, "items asked about once aren't asked again"
  end

  test "a model failure never stops the news leads" do
    Organization.create!(name: "Rolls-Royce SMR").verify!(by: "human:tosin")
    DataQuality::Stages::Crawl.call(plugin:)
    failing = Object.new.tap { |llm| def llm.structured(**) = raise(DataQuality::OpenRouter::Client::Error, "budget") }
    claims = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feeds: { "World Nuclear News" => FEED }, today: -> { Date.new(2026, 10, 15) },
      llm: failing, examined: ActiveSupport::Cache::MemoryStore.new).extract(source, nil)
    assert claims.any?, "news leads still come"
  end
end
