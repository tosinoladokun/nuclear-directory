require "test_helper"

# The admin's Today page (#373): four steps, stored per day, the same on
# every device.
class TodayTest < ActiveSupport::TestCase
  BY = "human:tosin"
  NOW = Time.utc(2026, 10, 20, 15) # 8am Pacific

  def today = Today.new(on: Date.new(2026, 10, 20), now: NOW)

  # Nothing waits in Checks: the fixtures' pending records are decided.
  def nothing_waiting!
    [ Organization, Facility ].each { |model| model.update_all(verification_status: "verified", verified_by: BY) }
  end

  def crawl!(kind, at, status: "succeeded") = CrawlRun.create!(stage: "crawl", source_kind: kind, status:, started_at: at)

  test "the day is the admin's, in Pacific time" do
    assert_equal Date.new(2026, 10, 19), Today.date(Time.utc(2026, 10, 20, 6))
    assert_equal Date.new(2026, 10, 20), Today.date(Time.utc(2026, 10, 20, 8))
  end

  test "the first step not done is the current one; the steps after it wait" do
    CorrectionReport.create!(subject: "TerraPower", page_path: "/companies/terrapower", message: "Wrong city.")
    assert_equal %i[current later later later], today.steps.map(&:state)

    today.mark_done!("crawl", by: BY)
    assert_equal %i[done current later later], today.steps.map(&:state)
    assert_equal 1, today.done_count
    assert_equal "list", today.current.key
  end

  test "a step is stored per day: another day starts again" do
    today.mark_done!("crawl", by: BY)

    assert_equal :current, Today.new(on: Date.new(2026, 10, 21), now: NOW + 1.day).step("crawl").state
  end

  test "no list today is a way to finish step 2; Undo opens it again" do
    t = today
    t.mark_done!("crawl", by: BY)
    t.mark_done!("list", by: BY, note: "no_list")
    assert_equal [ :done, "no_list", BY ], t.step("list").then { |step| [ step.state, step.note, step.done_by ] }

    t.undo!("list")
    assert_equal :current, t.step("list").state
  end

  test "marking a step again keeps the first time it was done" do
    today.mark_done!("list", by: BY, note: "no_list")
    today.mark_done!("list", by: BY)

    assert_equal "no_list", today.step("list").note
    assert_equal 1, TodayStep.count
  end

  test "steps 3 and 4 are done by themselves when nothing is left in them" do
    nothing_waiting!
    t = today
    assert_equal [ 0, 0 ], [ t.undecided, t.left_count ]
    assert_equal %i[current later done done], t.steps.map(&:state)

    t.mark_done!("crawl", by: BY)
    t.mark_done!("list", by: BY)
    assert t.done?
  end

  test "facts waiting and correction requests keep steps 3 and 4 open, and make the nav count" do
    nothing_waiting!
    CorrectionReport.create!(subject: "TerraPower", page_path: "/companies/terrapower", message: "Wrong city.")
    CorrectionReport.create!(subject: "Vogtle", page_path: "/plants/vogtle", message: "Fixed already.", status: "closed")
    Organization.create!(name: "Pending Fission Co")

    t = today
    assert_equal [ 1, 1, 2 ], [ t.undecided, t.left_count, t.nav_count ]
    assert_equal %i[later later], t.steps.last(2).map(&:state)
  end

  test "rough minutes: one each for steps 1 and 2, ten seconds a fact rounded up, a minute a visit" do
    nothing_waiting!
    7.times { |i| Organization.create!(name: "Pending Co #{i}") }
    CorrectionReport.create!(subject: "TerraPower", page_path: "/companies/terrapower", message: "Wrong city.")

    assert_equal [ 1, 1, 2, 1 ], today.steps.map(&:minutes), "7 facts at 10 seconds is 70 seconds: 2 minutes"
    assert_equal 5, today.minutes_total
  end

  test "last night's crawl: each kind of source once, by its latest run, and whether it failed" do
    crawl!("nrc_reactor_list", Time.utc(2026, 10, 19, 12)) # yesterday morning: not last night
    crawl!("nrc_reactor_list", Time.utc(2026, 10, 20, 7))
    crawl!("eia_generators", Time.utc(2026, 10, 20, 7, 5), status: "failed")
    crawl!("eia_generators", Time.utc(2026, 10, 20, 7, 30))
    crawl!("web_page", Time.utc(2026, 10, 20, 6, 30), status: "failed") # 11:30pm Pacific: within the margin

    rows = today.crawl_rows
    assert_equal %w[eia_generators nrc_reactor_list web_page], rows.map(&:source_kind)
    assert_equal [ false, false, true ], rows.map(&:failed), "a retry that worked isn't a problem"
    assert_equal [ 3, 1 ], [ today.step("crawl").count, today.crawl_problems ]
  end

  test "the reviewers' names come from one place each" do
    assert_equal [ "Joy", "Aminah" ], [ I18n.t("admin.reviewers.checker"), I18n.t("admin.reviewers.reviewer") ]
  end

  test "only a person marks a step, and only one of the four" do
    assert_raises(ActiveRecord::RecordInvalid) { today.mark_done!("crawl", by: "agent:verifier") }
    assert_raises(ActiveRecord::RecordInvalid) { today.mark_done!("lunch", by: BY) }
  end
end
