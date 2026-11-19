require "test_helper"

# #811: the pipeline's daily health: per-stage counts, and each problem a person must hear about.
class PipelineHealthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  NOW = Time.find_zone("America/Los_Angeles").local(2026, 11, 19, 7)

  setup { CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: NOW - 2.hours) }

  def health = PipelineHealth.new(now: NOW)

  test "counts each stage" do
    before = health.counts.values_at("leads_new", "pending_without_role", "pending_without_hq")
    Lead.sighted!(name: "Waiting Co", kind: "company", key: "news:w", label: "news")
    Organization.create!(name: "No Role Co", verification_status: "pending", created_at: NOW - 2.days)
    assert_equal before.map(&:succ), PipelineHealth.new(now: NOW).counts.values_at("leads_new", "pending_without_role", "pending_without_hq")
  end

  test "a pending company with no role for a day, a failed data deploy and a stale finder are problems" do
    Organization.create!(name: "No Role Co", verification_status: "pending", created_at: NOW - 2.days)
    DataDeploy.create!(status: "failed", error: "company 312 is no longer the pending 'cameco'", started_at: NOW - 1.hour)
    Lead.sighted!(name: "Waiting Co", kind: "company", key: "news:w", label: "news")
    problems = health.problems
    assert(problems.any? { |problem| problem.end_with?("pending companies have had no role for over a day") })
    assert(problems.any? { |problem| problem.start_with?("the last data deploy failed: company 312") })
    assert_includes problems, "the lead finder has never run"
  end

  test "no Creates for two weekdays while companies wait" do
    6.times { |n| Organization.create!(name: "Pending #{n}", verification_status: "pending") }
    [ Date.new(2026, 11, 17), Date.new(2026, 11, 18) ].each { |on| PipelineHealthSnapshot.create!(on:, counts: { "creates_shown" => 0 }) }
    assert(health.problems.any? { |problem| problem.start_with?("no Creates in Today for 2 weekdays") })
  end

  test "the daily job keeps the day's row and reports each problem" do
    Organization.create!(name: "No Role Co", verification_status: "pending", created_at: 2.days.ago)
    assert_difference("PipelineHealthSnapshot.count", 1) do
      assert_error_reported(PipelineHealthJob::Stalled) { PipelineHealthJob.perform_now }
    end
  end
end
