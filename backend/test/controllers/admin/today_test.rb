require "test_helper"

# Today (#373): the admin's daily plan, four steps, then done.
class Admin::TodayTest < ActionDispatch::IntegrationTest
  BANNED = /\b(claims?|verifiers?|candidates?|fingerprints?|safe class(es)?|S1)\b/i

  setup do
    sign_in_as users(:admin)
    @source = Source.create!(url: "https://www.nrc.gov/test/today.html", source_kind: "nrc_reactor_list", crawl_status: "ok", title: "NRC test page")
  end

  def main_text = css_select("main").text.squish
  def nothing_waiting! = [ Organization, Facility ].each { |model| model.update_all(verification_status: "verified", verified_by: "human:tosin") }

  test "the greeting, the four steps and their times; the first is open with last night's crawl" do
    travel_to Time.find_zone(Today::ZONE).local(2026, 10, 21, 9, 0) # a morning: last night's crawl window is the same at any run time
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.hours.ago)
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "succeeded", started_at: 2.hours.ago, stats: { "snapshot" => "error" })
    CorrectionReport.create!(subject: "TerraPower", page_path: "/companies/terrapower", message: "The city is wrong.")

    get admin_today_path

    assert_select "h1", "Here's what you need to do today, Tosin"
    assert_select "#today-progress", "0 of 4 done"
    assert_select ".nd-today__step", 4
    assert_select "#step-crawl[aria-current=step] .nd-today__sub", "2 sources · 1 problem · about 1 min"
    assert_select "#crawl-eia_generators", /EIA.*A page didn't answer/m
    assert_select "#step-list .nd-today__body", 0, "only the current step is open"
    assert_select "summary", "Who are Joy and Aminah?"
  end

  test "Looks fine marks step 1 done and opens step 2; Undo opens step 1 again" do
    post admin_today_step_path("crawl")
    follow_redirect!
    assert_select "#step-crawl.nd-today__step--done"
    assert_select "#step-list[aria-current=step] textarea[name=list]"

    delete admin_today_step_path("crawl")
    follow_redirect!
    assert_select "#step-crawl[aria-current=step]"
  end

  test "Aminah's list, added in full, finishes step 2; a line it can't read keeps the step open, with the list" do
    claim = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Alpha Fission Co" }, quote: "q", status: "matched",
      subject_type: "Organization", subject_id: Organization.create!(name: "Alpha Fission Co").id)
    post admin_today_step_path("crawl")

    post admin_today_list_path, params: { list: "#{claim.id} approve: named on the page\nplease approve the rest" }
    assert_response :unprocessable_content
    assert_select ".nd-alert", /Added 1 fact from Aminah\.\s+1 line wasn't added:.*please approve the rest/m
    assert_select "#step-list[aria-current=step] textarea", /please approve the rest/

    post admin_today_list_path, params: { list: "#{claim.id} approve: named on the page" }
    assert_equal "Added 1 fact from Aminah.", flash[:notice]
    follow_redirect!
    assert_select "#step-list.nd-today__step--done"
  end

  test "no list from Aminah today finishes step 2 and says so" do
    post admin_today_step_path("crawl")
    post admin_today_step_path("list"), params: { note: "no_list" }
    follow_redirect!

    assert_select "#step-list.nd-today__step--done .nd-today__sub", "No list today"
    assert_select "#step-review[aria-current=step] a[href=?]", admin_today_review_path, text: "Start reviewing ›"
    assert_select "#step-review[aria-current=step] a[href=?]", admin_checks_path, text: "The full list in Checks ›"
  end

  test "step 4 lists correction requests, each with a link to it" do
    nothing_waiting!
    report = CorrectionReport.create!(subject: "TerraPower", page_path: "/companies/terrapower", message: "The city is wrong.")
    post admin_today_step_path("crawl")
    post admin_today_step_path("list"), params: { note: "no_list" }
    follow_redirect!

    assert_select "#step-review.nd-today__step--done"
    assert_select "#left-report-#{report.id}", /TerraPower.*The city is wrong/m
    assert_select "#left-report-#{report.id} a[href=?]", admin_corrections_path(report: report.id), text: "Open the request ›"
  end

  test "a correction request past the first page opens on its own page" do
    nothing_waiting!
    reports = 51.times.map { |i| CorrectionReport.create!(subject: "Co #{i}", page_path: "/", message: "Fix #{i}.", created_at: i.minutes.ago) }
    last = reports.max_by { |report| [ -report.created_at.to_f, report.id ] }
    get admin_corrections_path(report: last.id)
    follow_redirect! while response.redirect?
    assert_select "#report-#{last.id}"
  end

  test "done for today when every step is done" do
    nothing_waiting!
    post admin_today_step_path("crawl")
    post admin_today_step_path("list"), params: { note: "no_list" }
    follow_redirect!

    assert_select "#today-progress", "4 of 4 done"
    assert_select "#done h2", "You're done for today."
    assert_select "#done .nd-tile", 3
  end

  test "the day's totals count a publish by hand, which has no claim, once" do
    company = Organization.create!(name: "Hand Published Co")
    Evidence.create!(subject: company, source: Source.create!(url: "https://example.com/hand", source_kind: "web_page"), quote: "q", found_by: "human")
    assert DataQuality::Review.publish(type: "Organization", id: company.id, by: "human:tosin").ok?

    totals = Today.new.decisions(by: "human:tosin")
    assert_equal [ 1, 0, 1 ], totals.values_at(:live, :rejected, :by_you)
  end

  test "the nav says Today, with facts waiting plus step 4's items" do
    nothing_waiting!
    Organization.create!(name: "Pending Co")
    CorrectionReport.create!(subject: "TerraPower", page_path: "/companies/terrapower", message: "Wrong city.")

    get admin_checks_path
    assert_select "nav a[href=?]", admin_today_path, /Today\s*2/
  end

  test "plain words only; the reviewers' names come from their keys" do
    I18n.backend.store_translations(:en, admin: { reviewers: { checker: "Ada", reviewer: "Bea" } })
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago)
    [ nil, "crawl", "list" ].each do |step|
      post admin_today_step_path(step), params: { note: ("no_list" if step == "list") } if step
      get admin_today_path
      assert_no_match BANNED, main_text
      assert_no_match(/Joy|Aminah/, main_text)
    end
    assert_select "#step-crawl .nd-today__title", /Crawled and checked by Ada/
  ensure
    I18n.reload!
  end
end
