require "test_helper"

class DataQuality::BudgetTest < ActiveSupport::TestCase
  def spend(cost, at: Time.current)
    CrawlRun.create!(stage: "extract", source_kind: "dummy", started_at: at, status: "succeeded",
      stats: { "llm" => { "calls" => 4, "total_tokens" => 12_000, "cost" => cost } })
  end

  test "adds up this month's model cost, ignoring last month's and runs without model calls" do
    spend(1.25)
    spend(0.75)
    spend(9.0, at: 1.month.ago)
    CrawlRun.create!(stage: "crawl", source_kind: "dummy")

    assert_in_delta 2.0, DataQuality::Budget.spent_this_month
  end

  test "refuses once the budget is used up, saying why" do
    spend(4.99)
    assert_nothing_raised { DataQuality::Budget.check!(5.0) }

    spend(0.02)
    error = assert_raises(DataQuality::Budget::Exceeded) { DataQuality::Budget.check!(5.0) }
    assert_match "Monthly model budget of $5.00 is used up ($5.0100 spent", error.message
    assert_match "DATA_QUALITY_MONTHLY_BUDGET", error.message
  end

  test "the client makes no call once the budget is used up, and the run fails visibly" do
    spend(5.5)
    config = DataQuality::Config.new(api_key: "test-key", extract_model: "a/x", verify_model: "b/y", monthly_budget: 5.0)
    client = DataQuality::OpenRouter::Client.new(config: config, sleeper: ->(_) { })
    run = CrawlRun.create!(stage: "extract", source_kind: "dummy")

    assert_raises(DataQuality::Budget::Exceeded) do
      client.structured(role: :extract, messages: [ { role: "user", content: "hi" } ], crawl_run: run,
        schema: { "type" => "object", "properties" => {}, "additionalProperties" => false })
    end
    assert_not_requested :post, DataQuality::OpenRouter::Client::ENDPOINT.to_s
  end

  test "a run that crosses midnight at month end counts each call in the month it was made" do
    config = DataQuality::Config.new(api_key: "test-key", extract_model: "a/x", verify_model: "b/y")
    client = DataQuality::OpenRouter::Client.new(config: config, sleeper: ->(_) { })
    schema = { "type" => "object", "properties" => {}, "additionalProperties" => false }
    completion = { status: 200, body: { choices: [ { message: { content: "{}" } } ],
      usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120, cost: 0.002 } }.to_json }
    stub_request(:post, DataQuality::OpenRouter::Client::ENDPOINT.to_s).to_return(completion)
    ask = ->(run) { client.structured(role: :extract, messages: [ { role: "user", content: "hi" } ], schema:, crawl_run: run) }

    run = nil
    travel_to(Time.zone.parse("2026-09-30 23:59")) do
      run = CrawlRun.create!(stage: "extract", source_kind: "dummy")
      ask.(run)
    end
    travel_to(Time.zone.parse("2026-10-01 00:01")) { 2.times { ask.(run) } }

    assert_equal({ "2026-09" => 1, "2026-10" => 2 }, run.reload.stats["llm"]["by_month"].transform_values { _1["calls"] })
    travel_to(Time.zone.parse("2026-10-15 12:00")) do
      assert_equal({ calls: 2, total_tokens: 240, cost: 0.004 }, DataQuality::Budget.usage_this_month)
      assert_match "2 calls, 240 tokens, $0.0040", DataQuality::StatusReport.call(budget: 5.0)
    end
  end

  test "a long-running run started weeks ago still counts its calls made this month" do
    CrawlRun.create!(stage: "verify", source_kind: "dummy", started_at: Time.zone.parse("2026-09-25 10:00"),
      stats: { "llm" => { "cost" => 3.0, "by_month" => {
        "2026-09" => { "calls" => 1, "total_tokens" => 10, "cost" => 1.0 },
        "2026-10" => { "calls" => 2, "total_tokens" => 20, "cost" => 2.0 } } } })

    travel_to(Time.zone.parse("2026-10-20 12:00")) do
      assert_equal({ calls: 2, total_tokens: 20, cost: 2.0 }, DataQuality::Budget.usage_this_month)
    end
  end

  test "a run in flight across the deploy keeps its earlier spend when its first monthly bucket appears" do
    config = DataQuality::Config.new(api_key: "test-key", extract_model: "a/x", verify_model: "b/y")
    client = DataQuality::OpenRouter::Client.new(config: config, sleeper: ->(_) { })
    stub_request(:post, DataQuality::OpenRouter::Client::ENDPOINT.to_s).to_return(status: 200,
      body: { choices: [ { message: { content: "{}" } } ], usage: { total_tokens: 100, cost: 0.01 } }.to_json)
    # Recorded the old way: totals only, $4.99 so far this month.
    run = CrawlRun.create!(stage: "verify", source_kind: "dummy",
      stats: { "llm" => { "calls" => 40, "total_tokens" => 50_000, "cost" => 4.99 } })

    client.structured(role: :verify, messages: [ { role: "user", content: "hi" } ], crawl_run: run,
      schema: { "type" => "object", "properties" => {}, "additionalProperties" => false })

    assert_equal({ calls: 41, total_tokens: 50_100, cost: 5.0 }, DataQuality::Budget.usage_this_month)
    assert_raises(DataQuality::Budget::Exceeded) { DataQuality::Budget.check!(5.0) }
  end

  test "runs recorded before per-month usage still count by the month they started" do
    spend(0.25) # no by_month, started this month
    spend(1.0, at: 1.month.ago)

    assert_in_delta 0.25, DataQuality::Budget.spent_this_month
  end

  # #95: historical reports pass a past now:. A legacy run (no by_month)
  # started in a later month would otherwise be counted against it, since
  # the fallback had only a lower bound on started_at.
  test "a historical month's usage ignores legacy runs started in a later month" do
    september = Time.zone.parse("2026-09-15 12:00")
    october = Time.zone.parse("2026-10-05 12:00")
    spend(1.0, at: september)
    spend(2.0, at: october)

    assert_equal 1.0, DataQuality::Budget.usage_this_month(now: september)[:cost]
    assert_equal 2.0, DataQuality::Budget.usage_this_month(now: october)[:cost]
  end

  test "the budget comes from DATA_QUALITY_MONTHLY_BUDGET, $5 by default" do
    assert_equal 5.0, DataQuality::Config.from_env({}).monthly_budget
    assert_equal 2.5, DataQuality::Config.from_env("DATA_QUALITY_MONTHLY_BUDGET" => "2.5").monthly_budget
    assert_equal 0.0, DataQuality::Config.from_env("DATA_QUALITY_MONTHLY_BUDGET" => "0").monthly_budget, "0 means no model calls"
  end

  test "a budget that isn't a number, or is negative, is a configuration error, not a $0 budget" do
    %w[five 5$ 5,00].each do |typo|
      error = assert_raises(DataQuality::Config::ConfigurationError) do
        DataQuality::Config.from_env("DATA_QUALITY_MONTHLY_BUDGET" => typo)
      end
      assert_match "must be a number of US dollars", error.message
    end

    error = assert_raises(DataQuality::Config::ConfigurationError) { DataQuality::Config.from_env("DATA_QUALITY_MONTHLY_BUDGET" => "-1") }
    assert_match "can't be negative", error.message
  end
end
