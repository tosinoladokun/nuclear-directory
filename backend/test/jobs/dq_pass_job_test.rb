require "test_helper"

# #998: Data Quality's daily pass. Off until switched on; one daily cap with
# the checker; a failed or capped run says so through Autopilot.
class DqPassJobTest < ActiveSupport::TestCase
  class Recorder
    attr_reader :raised, :resolved
    def initialize = (@raised, @resolved = [], [])
    def raise!(key, title:, body:, **) = @raised << [ key, title, body ]
    def resolve!(key, note: nil) = @resolved << key
  end

  NOW = Time.utc(2026, 12, 2, 10, 30)

  setup do
    @alerts = Recorder.new
    DqPassJob.alerts = @alerts
  end

  teardown do
    DqPassJob.alerts = nil
    DqPassJob.steps = nil
  end

  def spend(cost, kind: DqPass::SOURCE_KIND, at: NOW - 1.hour)
    CrawlRun.create!(source_kind: kind, stage: "verify", started_at: at, stats: { "llm" => { "cost" => cost } })
  end

  test "it does nothing while its switch is off, and a new switch is off" do
    called = false
    DqPassJob.steps = [ ->(_run) { called = true } ]

    assert_not DqPass.on?
    assert_equal({ "skipped" => "switched off" }, DqPassJob.perform_now(now: NOW))
    assert_not called
    assert_equal 0, CrawlRun.where(source_kind: DqPass::SOURCE_KIND).count

    Switch.set!(DqPass::KEY, true, by: "human:tosin")
    Switch.set!(DqPass::KEY, false, by: "human:tosin")
    DqPassJob.perform_now(now: NOW)
    assert_not called, "switched back off"
  end

  test "switched on, each step runs in order, its counts are kept on the run, and old alerts resolve" do
    Switch.set!(DqPass::KEY, true, by: "human:tosin")
    order = []
    DqPassJob.steps = [ ->(_run) { order << 1; { "websites" => 2 } }, ->(_run) { order << 2; { "websites" => 1, "rejects" => 3 } } ]

    DqPassJob.perform_now(now: NOW)

    run = CrawlRun.find_by!(source_kind: DqPass::SOURCE_KIND)
    assert_equal [ 1, 2 ], order
    assert_equal "succeeded", run.status
    assert_equal({ "websites" => 3, "rejects" => 3 }, run.stats.slice("websites", "rejects"))
    assert_equal [ DqPass::FAILED, DqPass::BUDGET ], @alerts.resolved
    assert_empty @alerts.raised
  end

  test "a failed run is marked failed, raises its alert and re-raises" do
    Switch.set!(DqPass::KEY, true, by: "human:tosin")
    DqPassJob.steps = [ ->(_run) { raise ArgumentError, "boom" } ]

    assert_raises(ArgumentError) { DqPassJob.perform_now(now: NOW) }

    assert_equal [ "failed", "boom" ], CrawlRun.find_by!(source_kind: DqPass::SOURCE_KIND).values_at(:status, :error)
    assert_equal [ DqPass::FAILED ], @alerts.raised.map(&:first)
  end

  test "the cap stops the steps, keeps the run, and raises its own alert, not a failure" do
    Switch.set!(DqPass::KEY, true, by: "human:tosin")
    second = false
    DqPassJob.steps = [ ->(_run) { DqPass.check_budget!(now: NOW) || {} }, ->(_run) { second = true } ]
    spend(0.6, kind: DqChecker::SOURCE_KIND)
    spend(0.4)

    DqPassJob.perform_now(now: NOW)

    assert_not second
    run = CrawlRun.where(source_kind: DqPass::SOURCE_KIND).order(:id).last
    assert_equal [ "succeeded", 1 ], [ run.status, run.stats["stopped_for_budget"] ]
    assert_equal [ DqPass::BUDGET ], @alerts.raised.map(&:first)
    assert_equal [ DqPass::FAILED ], @alerts.resolved
  end

  test "the cap counts the pass and the checker together, today (UTC) only" do
    spend(0.5, kind: DqChecker::SOURCE_KIND)
    spend(0.4)
    spend(5.0, at: NOW - 1.day)
    assert_in_delta 0.9, DqPass.spent_today(now: NOW)
    assert DqPass.budget_left?(now: NOW)

    spend(0.1)
    assert_not DqPass.budget_left?(now: NOW)
    assert_raises(DqPass::BudgetReached) { DqPass.check_budget!(now: NOW) }
  end

  test "stalled: only while on, after a day and two hours with no finished run" do
    assert_nil DqPass.stalled(now: NOW), "off"

    travel_to(NOW - 2.days) { Switch.set!(DqPass::KEY, true, by: "human:tosin") }
    assert_match "hasn't finished a run", DqPass.stalled(now: NOW)

    CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify", status: "succeeded", started_at: NOW - 3.hours, finished_at: NOW - 3.hours)
    assert_nil DqPass.stalled(now: NOW)
    assert_match "since", DqPass.stalled(now: NOW + 1.day)
    assert_includes PipelineHealth.new(now: NOW + 1.day).checks.keys, DqPass::STALLED

    Switch.set!(DqPass::KEY, false, by: "human:tosin")
    assert_nil DqPass.stalled(now: NOW + 1.day), "off again"
  end

  test "a just switched-on pass isn't stalled before its first night" do
    travel_to(NOW - 1.hour) { Switch.set!(DqPass::KEY, true, by: "human:tosin") }
    assert_nil DqPass.stalled(now: NOW)
  end
end
