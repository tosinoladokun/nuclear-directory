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

  test "a failure stays a problem while its retry is still running" do
    crawl!("eia_generators", Time.utc(2026, 10, 20, 7), status: "failed")
    crawl!("eia_generators", Time.utc(2026, 10, 20, 7, 30), status: "running")

    row = today.crawl_rows.sole
    assert [ row.failed, row.running ].all?
  end

  test "a run that succeeded but didn't read its source is a problem" do
    { "nrc_reactor_list" => { "list" => "blocked", "stopped" => "list page blocked" },
      "eia_generators" => { "file" => "https://www.eia.gov/x.xlsx", "snapshot" => "needs_human" },
      "usaspending_doe_awards" => { "api" => "failed" },
      "eia_860m_index" => { "api" => "skipped_recent" } }.each do |kind, stats|
      CrawlRun.create!(stage: "crawl", source_kind: kind, status: "succeeded", started_at: Time.utc(2026, 10, 20, 7), stats:)
    end

    problems = today.crawl_rows.to_h { |row| [ row.source_kind, row.problem ] }
    assert_equal "list page blocked", problems["nrc_reactor_list"]
    assert_equal "a file it couldn't read needs a person", problems["eia_generators"]
    assert_equal "the API answered failed", problems["usaspending_doe_awards"]
    assert_nil problems["eia_860m_index"], "a same-day rerun that skipped the fetch isn't a problem"
    assert_equal 3, today.crawl_problems
  end

  test "a fetch that errored or that robots.txt refused is a problem, whichever stat holds it" do
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "succeeded", started_at: Time.utc(2026, 10, 20, 7),
      stats: { "file" => "https://www.eia.gov/x.xlsx", "snapshot" => "error" })
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_power_status", status: "succeeded", started_at: Time.utc(2026, 10, 20, 7),
      stats: { "status_file" => "disallowed" })

    assert_equal({ "eia_generators" => "a page didn't answer", "nrc_power_status" => "robots.txt refused a page" },
      today.crawl_rows.to_h { |row| [ row.source_kind, row.problem ] })
  end

  test "a same-day rerun that skipped its fetch neither clears a problem nor makes one" do
    blocked = { "api" => "blocked" }
    skipped = { "api" => "skipped_recent" }
    CrawlRun.create!(stage: "crawl", source_kind: "usaspending_doe_awards", status: "succeeded", started_at: Time.utc(2026, 10, 20, 7), stats: blocked)
    CrawlRun.create!(stage: "crawl", source_kind: "usaspending_doe_awards", status: "succeeded", started_at: Time.utc(2026, 10, 20, 8), stats: skipped)
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "succeeded", started_at: Time.utc(2026, 10, 20, 7), stats: { "snapshot" => "changed" })
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "succeeded", started_at: Time.utc(2026, 10, 20, 8), stats: { "snapshot" => "skipped_recent" })

    problems = today.crawl_rows.to_h { |row| [ row.source_kind, row.problem ] }
    assert_equal "a page was blocked", problems["usaspending_doe_awards"], "blocked, then skipped: still blocked"
    assert_nil problems["eia_generators"], "read, then skipped: still fine"
  end

  test "each read keeps its own last outcome when a rerun skips some reads and makes others" do
    at = ->(hour) { Time.utc(2026, 10, 20, hour) }
    run = ->(kind, hour, stats) { CrawlRun.create!(stage: "crawl", source_kind: kind, status: "succeeded", started_at: at.(hour), stats:) }
    # The list was blocked; the retry skipped it and read the status file.
    run.("nrc_reactor_list", 7, { "list" => "blocked", "stopped" => "list page blocked" })
    run.("nrc_reactor_list", 8, { "list" => "skipped_recent", "status_file" => "changed" })
    # The list was read; the retry skipped it and the status file failed.
    run.("nrc_power_status", 7, { "list" => "changed", "status_file" => "changed" })
    run.("nrc_power_status", 8, { "list" => "skipped_recent", "status_file" => "error" })

    problems = today.crawl_rows.to_h { |row| [ row.source_kind, row.problem ] }
    assert_equal "a page was blocked", problems["nrc_reactor_list"], "the list was never read again"
    assert_equal "a page didn't answer", problems["nrc_power_status"], "a fresh failure isn't hidden by a skipped read"
  end

  test "failed reads counted inside a stat count; zero failures don't" do
    run = ->(kind, site_pages) do
      CrawlRun.create!(stage: "crawl", source_kind: kind, status: "succeeded", started_at: Time.utc(2026, 10, 20, 7),
        stats: { "list" => "changed", "site_pages" => site_pages })
    end
    run.("nrc_decommissioning", { "changed" => 19, "error" => 1 })
    run.("nrc_uranium_recovery", { "unchanged" => 4, "disallowed" => 1 })
    run.("doe_isotope_sites", { "changed" => 3, "error" => 0 })

    problems = today.crawl_rows.to_h { |row| [ row.source_kind, row.problem ] }
    assert_equal [ "a page didn't answer", "robots.txt refused a page", nil ],
      problems.values_at("nrc_decommissioning", "nrc_uranium_recovery", "doe_isotope_sites")
  end

  test "marking a step reads the counts again, so facts added since keep step 3 open" do
    nothing_waiting!
    t = today
    assert t.step("review").done?, "nothing waits yet"

    Organization.create!(name: "Pending From The List Co")
    t.mark_done!("crawl", by: BY)
    t.mark_done!("list", by: BY)
    assert_equal :current, t.step("review").state
    assert_not t.done?
  end

  test "the reviewers' names come from one place each" do
    assert_equal [ "Joy", "Aminah" ], [ I18n.t("admin.reviewers.checker"), I18n.t("admin.reviewers.reviewer") ]
  end

  test "only a person marks a step, and only one of the four" do
    assert_raises(ActiveRecord::RecordInvalid) { today.mark_done!("crawl", by: "agent:verifier") }
    assert_raises(ActiveRecord::RecordInvalid) { today.mark_done!("lunch", by: BY) }
  end
end
