require "test_helper"

# Says so the same morning when an approved post didn't go out (#912).
class SocialQueueWatchJobTest < ActiveSupport::TestCase
  ZONE = Time.find_zone(SocialAgent::ZONE)
  MONDAY = ZONE.local(2026, 11, 23, 9, 0)

  # Stands in for Autopilot::Alert: records what it is told.
  class Recorder
    attr_reader :raised, :resolved
    def initialize = (@raised, @resolved = [], [])
    def raise!(key, title:, body:, **) = @raised << [ key, title, body ]
    def resolve!(key, note: nil) = @resolved << key
  end

  setup do
    @company = Organization.create!(name: "Acme Fission", slug: "acme-fission", verification_status: "verified", verified_by: "human:tosin", verified_at: 1.year.ago)
    SocialChannel.for("x").update!(mode: "drafts")
    SocialChannel.for("linkedin").update!(mode: "drafts")
    @alerts = Recorder.new
    SocialQueueWatchJob.alerts = @alerts
  end

  teardown { SocialQueueWatchJob.alerts = nil }

  def post(attrs) = SocialPost.create!({ platform: "x", subject: @company, text: "A secret text", created_at: MONDAY - 1.day }.merge(attrs))
  def run_job(now = MONDAY) = SocialQueueWatchJob.perform_now(now:)

  test "an approved row due today that is still a draft raises one alert with ids and slugs, never the text" do
    waiting = post(status: "drafted", send_on: MONDAY.to_date)
    run_job

    key, _title, body = @alerts.raised.sole
    assert_equal "social-queue", key
    assert_includes body, "Row #{waiting.id} (x, acme-fission) was due 2026-11-23 and is still a draft"
    assert_not_includes body, "secret"
    assert_empty @alerts.resolved
  end

  def stopped_run(platform, why, at: MONDAY - 30.minutes)
    CrawlRun.create!(source_kind: SocialAgent::STOPPED, stage: "verify", status: "succeeded", started_at: at, finished_at: at,
      stats: { "platform" => platform, "stopped" => why })
  end

  test "the stopped run's reason is added to its own row only, the latest run for that row winning" do
    x_row = post(status: "drafted", send_on: MONDAY.to_date)
    linkedin_row = post(platform: "linkedin", status: "drafted", send_on: MONDAY.to_date)
    stopped_run("x", "approved draft #{x_row.id} not sent: it's a holiday", at: MONDAY - 40.minutes)
    stopped_run("x", "approved draft #{x_row.id} not sent: its source page no longer answers (404)")
    stopped_run("linkedin", "approved draft #{x_row.id + 1000} not sent: sending is off on the server (SOCIAL_POSTING_ENABLED)")
    stopped_run("x", "approved draft #{linkedin_row.id} not sent: this month's 20 posts are done")
    run_job

    lines = @alerts.raised.sole[2].lines
    assert_includes lines.grep(/Row #{x_row.id} /).sole, "is still a draft: its source page no longer answers (404)."
    assert_includes lines.grep(/Row #{linkedin_row.id} /).sole, "is still a draft."
    body = lines.join
    %w[holiday SOCIAL_POSTING_ENABLED month].each { |unrelated| assert_not_includes body, unrelated }
  end

  test "a stopped reason that isn't fixed wording (an error, a Buffer reply) is never forwarded" do
    row = post(status: "drafted", send_on: MONDAY.to_date)
    stopped_run("x", "approved draft #{row.id} not sent: RuntimeError: Buffer said A secret text token=abc123")
    blocked = post(platform: "linkedin", status: "blocked", approved_sha256: "b" * 64, send_on: MONDAY.to_date, reason: "Faraday::Error: A secret text token=abc123")
    run_job

    body = @alerts.raised.sole[2]
    assert_includes body, "Row #{row.id} (x, acme-fission) was due 2026-11-23 and is still a draft: see Admin > Posts for why."
    assert_includes body, "Row #{blocked.id} (linkedin, acme-fission) is an approved post that a check blocked: see Admin > Posts for why"
    %w[secret token abc123 RuntimeError Faraday].each { |leak| assert_not_includes body, leak }
  end

  test "a row sent today that failed or is unknown is named; unknown says to check the account" do
    failed = post(status: "failed", sent_on: MONDAY.to_date)
    unknown = post(platform: "linkedin", status: "unknown", sent_on: MONDAY.to_date)
    run_job

    body = @alerts.raised.sole[2]
    assert_includes body, "Row #{failed.id} (x, acme-fission) is failed."
    assert_includes body, "Row #{unknown.id} (linkedin, acme-fission) is unknown (it may have gone out: check the account)."
  end

  test "an approved row that a check blocked is named with its reason; a blocked agent draft is not" do
    blocked = post(status: "blocked", approved_sha256: "a" * 64, send_on: MONDAY.to_date, reason: "its checks no longer pass: A secret text")
    post(platform: "linkedin", status: "blocked", reason: "the agent's own draft")
    run_job

    body = @alerts.raised.sole[2]
    assert_includes body, "Row #{blocked.id} (x, acme-fission) is an approved post that a check blocked: its checks no longer pass"
    assert_not_includes body, "secret"
    assert_equal 1, body.scan("Row ").size
  end

  test "a row claimed for sending today that send_post then blocked (the month's cap) is named, approved by hand or by graders" do
    by_hand = post(status: "blocked", sent_on: MONDAY.to_date, reason: "this month's 20 posts are done")
    graded = post(platform: "linkedin", status: "blocked", approved_sha256: "c" * 64, send_on: MONDAY.to_date, sent_on: MONDAY.to_date, reason: "this month's cap of $5.0 is reached")
    run_job

    body = @alerts.raised.sole[2]
    assert_includes body, "Row #{by_hand.id} (x, acme-fission) is an approved post that a check blocked: this month's 20 posts are done"
    assert_includes body, "Row #{graded.id} (linkedin, acme-fission) is an approved post that a check blocked: this month's cap of $5.0 is reached"
    assert_empty @alerts.resolved
  end

  test "a queued row more than 30 minutes past its Buffer due time is named; a recent one is not" do
    late = post(status: "queued", posted_at: MONDAY - 40.minutes, sent_on: MONDAY.to_date)
    post(platform: "linkedin", status: "queued", posted_at: MONDAY - 10.minutes, sent_on: MONDAY.to_date)
    run_job

    body = @alerts.raised.sole[2]
    assert_includes body, "Row #{late.id} (x, acme-fission) is still queued 40 minutes"
    assert_equal 1, body.scan("Row ").size
  end

  test "nothing wrong resolves the alert; posted and cancelled rows are fine" do
    post(status: "posted", sent_on: MONDAY.to_date)
    post(platform: "linkedin", status: "cancelled", send_on: nil)
    run_job

    assert_empty @alerts.raised
    assert_equal [ "social-queue" ], @alerts.resolved
  end

  test "a platform that is switched off is not watched" do
    SocialChannel.for("x").update!(mode: "off")
    post(status: "drafted", send_on: MONDAY.to_date)
    run_job

    assert_empty @alerts.raised
  end

  test "weekends and holidays do nothing" do
    post(status: "drafted", send_on: Date.new(2026, 11, 21))
    run_job(ZONE.local(2026, 11, 21, 9, 0))
    run_job(ZONE.local(2026, 11, 26, 9, 0)) if SocialAgent::Rules.holiday?(Date.new(2026, 11, 26))

    assert_empty @alerts.raised
    assert_empty @alerts.resolved
  end

  test "the alert is keyed to Infra and scheduled after the 8:30 run" do
    assert_equal "Infra", Autopilot::Owners.for(SocialQueueWatchJob::KEY)
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml")).fetch("production").fetch("social_queue_watch")
    assert_equal "SocialQueueWatchJob", schedule["class"]
    assert_match(/\A0,45 9 \* \* 1-5 /, schedule["schedule"])
  end
end
