require "test_helper"

# #811: the pipeline's daily health: per-stage counts, and each problem a person must hear about.
class PipelineHealthTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

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
    assert_includes problems, "the last data deploy failed (see the deploy report)"
    assert_includes problems, "the lead finder has never run"
  end

  test "no Creates for two weekdays while companies wait" do
    6.times { |n| Organization.create!(name: "Pending #{n}", verification_status: "pending") }
    [ Date.new(2026, 11, 17), Date.new(2026, 11, 18) ].each { |on| PipelineHealthSnapshot.create!(on:, counts: { "creates_shown" => 0 }) }
    today = health
    today.define_singleton_method(:creates_shown) { 0 } # none in Today now (its own selection)
    assert(today.problems.any? { |problem| problem.start_with?("no Creates in Today for 2 weekdays") })
  end

  test "the daily job keeps the day's row and emails the problems (Sentry is captured directly, outside tests)" do
    Organization.create!(name: "No Role Co", verification_status: "pending", created_at: 2.days.ago)
    ENV["RESEND_API_KEY"] = "dummy"
    assert_difference("PipelineHealthSnapshot.count", 1) do
      assert_enqueued_email_with(HealthMailer, :stalled, params: ->(params) { params[:problems].any? }) { PipelineHealthJob.perform_now }
    end
    mail = HealthMailer.with(problems: [ "1 pending companies have had no role for over a day" ]).stalled
    assert_equal [ "hello@nuclear-directory.org" ], mail.to
    assert_match "/admin/health", mail.body.encoded
  ensure
    ENV.delete("RESEND_API_KEY")
  end

  test "a pending company Data Quality said no to isn't counted; no website for two days, unjudged claims and stuck leads are problems" do
    before = health.counts["pending_companies"]
    junk = Organization.create!(name: "Junk Co", verification_status: "pending", created_at: NOW - 3.days)
    page = Source.create!(url: "https://example.com/junk", source_kind: "dummy", crawl_status: "ok")
    Candidate.create!(source: page, kind: "organization", payload: { "name" => "Junk Co" }, quote: "q", status: "matched", proposed_subject: true,
      subject_type: "Organization", subject_id: junk.id, dq_recommendation: "reject", dq_reason: "not nuclear")
    assert_equal before, health.counts["pending_companies"]

    Organization.create!(name: "No Site Co", verification_status: "pending", created_at: NOW - 3.days)
    Candidate.create!(source: page, kind: "organization", payload: { "name" => "Old Claim" }, quote: "q", status: "new", created_at: NOW - 5.days)
    Lead.sighted!(name: "Old Lead Co", kind: "company", key: "news:o", label: "news").update_columns(created_at: NOW - 3.days)
    problems = PipelineHealth.new(now: NOW).problems
    assert(problems.any? { |problem| problem.include?("no website for over two days") })
    assert(problems.any? { |problem| problem.include?("company claims have no verdict yet") })
    assert(problems.any? { |problem| problem.include?("leads are stuck") })
  end

  test "each check has a stable key; the job raises the stalled ones and resolves the rest through Autopilot::Alert" do
    Organization.create!(name: "No Role Co", verification_status: "pending", created_at: 2.days.ago)
    calls = []
    alert = Module.new
    alert.define_singleton_method(:raise!) { |key, **| calls << [ :raise, key ] }
    alert.define_singleton_method(:resolve!) { |key, **| calls << [ :resolve, key ] }
    Object.const_set(:Autopilot, Module.new) unless defined?(Autopilot)
    Autopilot.const_set(:Alert, alert) unless defined?(Autopilot::Alert)
    PipelineHealthJob.perform_now
    assert_includes calls, [ :raise, "pending-without-role" ]
    assert_includes calls, [ :resolve, "posts-unknown" ]
    assert_equal PipelineHealth.new.checks.keys.size, calls.size, "every key, once"
  ensure
    Autopilot.send(:remove_const, :Alert) if defined?(Autopilot::Alert) && Autopilot::Alert == alert
  end

  test "the finder's own rows mark it alive; a role without a source still counts as no role; hourly feeds don't hide the crawl" do
    CrawlRun.delete_all
    CrawlRun.create!(source_kind: "lead_forwards", stage: "crawl", status: "succeeded", started_at: NOW - 1.hour)
    assert_nil health.counts["last_crawl_at"], "an hourly feed isn't the nightly crawl"
    CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", started_at: NOW - 2.hours, stats: { "finds" => 1 })
    assert_equal 1, PipelineHealth.new(now: NOW).counts["finds_last_day"]

    company = Organization.create!(name: "Unsourced Role Co", verification_status: "pending", created_at: NOW - 2.days)
    before = PipelineHealth.new(now: NOW).counts["pending_without_role"]
    OrganizationRole.create!(organization: company, role: Role.first || Role.create!(key: "fuel", name: "Fuel"), verification_status: "pending")
    assert_equal before, PipelineHealth.new(now: NOW).counts["pending_without_role"], "no evidence: still blocks its Create"
  end

  test "finds held for a day with no search answering is the search limit; one search answering clears it" do
    Lead.sighted!(name: "Held Co", kind: "company", key: "news:h", label: "news").update!(status: "researching", note: LeadFinding::BUSY)
    assert_includes PipelineHealth.new(now: NOW).checks["search-limit"].to_s, "the search didn't answer"
    CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", started_at: NOW - 1.hour,
      stats: { DataQuality::Plugins::LeadFinder::USAGE => 1 })
    assert_nil PipelineHealth.new(now: NOW).checks["search-limit"]
  end

  test "a scheduled source that hasn't crawled in three days is named" do
    kinds = DataQuality::DailyCrawlJob::SOURCE_KINDS + PipelineHealth::RECURRING_SOURCES
    kinds.each { |kind| CrawlRun.create!(source_kind: kind, stage: "crawl", status: "succeeded", started_at: NOW - 1.hour) }
    assert_nil PipelineHealth.new(now: NOW).checks["sources-silent"]
    CrawlRun.where(source_kind: "nrc_news").update_all(started_at: NOW - 4.days)
    assert_equal "1 sources haven't run in three days: nrc_news", PipelineHealth.new(now: NOW).checks["sources-silent"]
  end
end
