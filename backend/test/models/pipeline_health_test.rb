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
    PipelineHealthJob.alerts = false # no Autopilot::Alert: the fallback email
    assert_difference("PipelineHealthSnapshot.count", 1) do
      assert_enqueued_email_with(HealthMailer, :stalled, params: ->(params) { params[:problems].any? }) { PipelineHealthJob.perform_now }
    end
    mail = HealthMailer.with(problems: [ "1 pending companies have had no role for over a day" ]).stalled
    assert_equal [ "hello@nuclear-directory.org" ], mail.to
    assert_match "/admin/health", mail.body.encoded
  ensure
    PipelineHealthJob.alerts = nil
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
    PipelineHealthJob.alerts = alert
    PipelineHealthJob.perform_now
    assert_includes calls, [ :raise, "pending-without-role" ]
    assert_includes calls, [ :resolve, "posts-unknown" ]
    assert_equal PipelineHealth.new.checks.keys.size, calls.size, "every key, once"
  ensure
    PipelineHealthJob.alerts = nil
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

  test "finds held for the search itself with none answered is the search limit; a reserved but failed search doesn't hide it" do
    Lead.sighted!(name: "Held Co", kind: "company", key: "news:h", label: "news")
      .update!(status: "researching", note: "Waiting: Today's search limit is reached; tried again tomorrow")
    CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", started_at: NOW - 1.hour,
      stats: { DataQuality::Plugins::LeadFinder::USAGE => 1 }) # reserved before a request that then failed
    assert_includes PipelineHealth.new(now: NOW).checks["search-limit"].to_s, "the search didn't answer"

    Lead.sighted!(name: "Lock Co", kind: "company", key: "news:l", label: "news").update!(status: "researching", note: LeadFinding::BUSY)
    assert_equal 1, PipelineHealth.new(now: NOW).counts["searches_held_last_day"], "the pipeline lock's BUSY isn't the search"

    Lead.sighted!(name: "Found Co", kind: "company", key: "news:f", label: "news").update!(status: "added")
    assert_nil PipelineHealth.new(now: NOW).checks["search-limit"], "a find that got an answer clears it"
  end

  test "a scheduled source that hasn't crawled in three days is named" do
    kinds = DataQuality::DailyCrawlJob::SOURCE_KINDS + PipelineHealth::RECURRING_SOURCES
    kinds.each { |kind| CrawlRun.create!(source_kind: kind, stage: "crawl", status: "succeeded", started_at: NOW - 1.hour) }
    assert_nil PipelineHealth.new(now: NOW).checks["sources-silent"]
    CrawlRun.where(source_kind: "nrc_news").update_all(started_at: NOW - 4.days)
    assert_equal "1 sources haven't run in three days: nrc_news", PipelineHealth.new(now: NOW).checks["sources-silent"]
  end

  test "sources Crawl marks as not scheduled (a Hash of kind => why) are skipped, never a crash" do
    daily = DataQuality::DailyCrawlJob
    had = daily.const_defined?(:NOT_SCHEDULED, false) && daily::NOT_SCHEDULED
    daily.send(:remove_const, :NOT_SCHEDULED) if had
    daily.const_set(:NOT_SCHEDULED, { "nrc_news" => "read by its own job" })
    (daily::SOURCE_KINDS + PipelineHealth::RECURRING_SOURCES - [ "nrc_news" ]).each do |kind|
      CrawlRun.create!(source_kind: kind, stage: "crawl", status: "succeeded", started_at: NOW - 1.hour)
    end
    assert_nil PipelineHealth.new(now: NOW).checks["sources-silent"]
  ensure
    daily.send(:remove_const, :NOT_SCHEDULED)
    daily.const_set(:NOT_SCHEDULED, had) if had
  end

  test "IndexNow refused twice in a row alerts; an accepted batch clears it" do
    IndexNowSubmission.create!(urls: 3, accepted: false)
    assert_nil PipelineHealth.new(now: NOW).checks["indexnow-refused"], "one refusal is not enough"
    IndexNowSubmission.create!(urls: 3, accepted: false)
    assert_includes PipelineHealth.new(now: NOW).checks["indexnow-refused"].to_s, "refused the last two"
    IndexNowSubmission.create!(urls: 3, accepted: true)
    assert_nil PipelineHealth.new(now: NOW).checks["indexnow-refused"]
  end

  test "a database restart in the last day is named with its time; older is fine (Infra)" do
    started = ActiveRecord::Base.connection.select_value("select pg_postmaster_start_time()")
    started = Time.zone.parse(started.to_s) unless started.respond_to?(:utc)
    assert_match(/\AThe database restarted at \d\d:\d\d UTC/, PipelineHealth.new(now: started + 1.hour).checks["db-restarted"])
    assert_nil PipelineHealth.new(now: started + 25.hours).checks["db-restarted"]
  end
end
