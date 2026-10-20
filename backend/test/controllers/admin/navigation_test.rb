require "test_helper"

# Moving around the admin (#269): every stage in the nav (unbuilt ones as
# "Soon"), breadcrumbs that keep the list, Previous and Next through it,
# 303s after every decision, and Approve N safe only over what's shown.
class Admin::NavigationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @nrc = Source.create!(url: "https://www.nrc.gov/test/nav.html", source_kind: "nrc_reactor_list", crawl_status: "ok")
    @web = Source.create!(url: "https://www.sec.gov/nav.htm", source_kind: "web_page", crawl_status: "ok")
    sign_in_as users(:admin)
  end

  def org(name) = Organization.create!(name:)

  def waiting(name, source: @nrc, recommended: false, kind: "organization", payload: { "name" => name })
    subject = org(name) if kind == "organization"
    Candidate.create!(source:, kind:, payload:, quote: "q", subject_type: subject&.class&.name, subject_id: subject&.id,
      **(recommended ? { status: "matched", ai_recommendation: "recommend_publish" } : { status: "needs_review", notes: "unsure" }))
  end

  test "the nav lists every stage; unbuilt ones are marked Soon and aren't links" do
    get admin_root_path

    labels = css_select(".nd-shell__nav > *").map { |item| item.text.squish }
    assert_equal [ "Overview", "Sources", "Today", "Live", "Removed, Soon", "Where it appears, Soon", "Correction requests" ],
      labels.map { |label| label.sub(/ \d+\z/, "") }
    %w[Removed].each do |stage|
      assert_select ".nd-shell__nav span.nd-shell__soon", /#{stage}/ do
        assert_select ".nd-tag", "Soon"
      end
      assert_select ".nd-shell__nav a", text: /#{stage}/, count: 0
    end
  end

  test "a fact opened from Checks has a breadcrumb back to that list, and Previous and Next through it in its order" do
    a, b, c = %w[Alpha Beta Gamma].map { |name| waiting("#{name} Co") }
    waiting("Elsewhere Co", source: @web)
    back = admin_checks_path(source: "nrc_reactor_list")
    open = ->(candidate) { get admin_fact_path(type: "Organization", id: candidate.subject_id, from: "checks", back:) }

    open.(b)

    assert_select ".nd-crumbs li a[href=?]", back, text: "Checks"
    assert_select ".nd-crumbs li[aria-current=page]", "Beta Co"
    assert_select ".nd-crumbs__back[href=?]", back, text: "‹ Checks"
    assert_select ".nd-itemnav", /2 of 3/
    assert_select ".nd-itemnav a[rel=prev][href=?]", admin_fact_path(type: "Organization", id: a.subject_id, from: "checks", back:, claim: a.id)
    assert_select ".nd-itemnav a[rel=next][href=?]", admin_fact_path(type: "Organization", id: c.subject_id, from: "checks", back:, claim: c.id)

    open.(c)
    assert_select ".nd-itemnav", /3 of 3/
    assert_select ".nd-itemnav a[rel=next]", 0
    assert_select ".nd-itemnav span", "Next ›"
  end

  test "a back value outside the admin is ignored" do
    c = waiting("Alpha Co")
    [ "https://evil.example/admin", "//evil.example/admin", "/administrator", "javascript:alert(1)" ].each do |back|
      get admin_fact_path(type: "Organization", id: c.subject_id, from: "checks", back:, claim: c.id)
      assert_select ".nd-crumbs li a[href=?]", admin_checks_path, { text: "Checks" }, back
    end
  end

  test "edit, then approve opens the next claim in the list, and the list after the last" do
    a = waiting("Alpha Co")
    b = waiting("Beta Co")
    back = admin_checks_path(category: "facts")

    get edit_admin_candidate_path(a, back:)
    assert_select ".nd-itemnav", /1 of 2/

    patch admin_candidate_path(a, back:), params: { values: { name: "Alpha Co" } }
    assert_response :see_other
    assert_redirected_to edit_admin_candidate_path(b, back:)

    patch admin_candidate_path(b, back:), params: { values: { name: "Beta Co" } }
    assert_redirected_to back
    assert_equal "Approved 1 item.", flash[:notice]
  end

  test "every decision redirects with 303, back to the list at the next row" do
    a = waiting("Alpha Co")
    report = CorrectionReport.create!(subject: "TerraPower", page_path: "/", message: "Typo.")
    fact = organizations(:terrapower)
    fact.verify!(by: "human:tosin")

    post reject_admin_candidates_path(category: "facts"), params: { candidate_id: a.id, anchor: "claim-999" }
    assert_response :see_other
    assert_redirected_to admin_checks_path(category: "facts", anchor: "claim-999")

    post approve_admin_candidates_path, params: { candidate_id: a.id, anchor: "javascript:x" }
    assert_redirected_to admin_checks_path, "an anchor that isn't a row is dropped"

    post fix_admin_correction_path(report)
    assert_response :see_other
    post admin_fact_unpublish_path(type: "Organization", id: fact.id), params: { reason: "Test" }
    assert_response :see_other
    post approve_admin_pending_facts_path, params: { type: "Organization", id: fact.id }
    assert_response :see_other
    post approve_all_admin_candidates_path, params: { shown: "x" }
    assert_response :see_other
  end

  test "a decision on a later page of Checks comes back to that page" do
    stub_const(Admin::ChecksController, :PAGE, 2) do
      claims = 3.times.map { |n| waiting("Co #{n}") }
      page_two = admin_checks_path(after: claims[1].id)

      get page_two
      assert_select "#claim-#{claims[2].id} input[name=back][value=?]", page_two
      css_select("li[id^=fact-]").first&.then { |row| assert_select "##{row['id']} input[name=back][value=?]", page_two }

      post reject_admin_candidates_path, params: { candidate_id: claims[2].id, back: page_two }
      assert_redirected_to page_two
    end
  end

  test "a claim outside Changed that would replace a human-verified value still shows it, with Keep" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", verification_status: "verified", verified_by: "human:tosin")
    claim = Candidate.create!(source: @nrc, kind: "facility", quote: "q", status: "needs_review", notes: "unsure",
      subject_type: "Facility", subject_id: unit.id, payload: { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })

    get admin_checks_path(category: "facts")

    assert_select "#claim-#{claim.id}" do
      assert_select ".type-change", "NJ → DE"
      assert_select "details p", /Approving replaces the human-verified state/
      assert_select "button[formaction]", "Keep"
    end
  end

  test "Approve N safe counts and approves only the recommended claims the filter shows" do
    nrc = 2.times.map { |n| waiting("NRC Co #{n}", recommended: true) }
    waiting("Web Co", source: @web, recommended: true)
    waiting("Unsure Co")

    get admin_checks_path(source: "nrc_reactor_list")
    assert_select "form[action=?] button", approve_all_admin_candidates_path(source: "nrc_reactor_list"), "Approve 2 safe"
    shown = css_select("input[name=shown]").first["value"]

    post approve_all_admin_candidates_path(source: "nrc_reactor_list"), params: { shown: }

    job = enqueued_jobs.find { |queued| queued["job_class"] == "DataQuality::ApproveAllJob" }
    assert_equal nrc.map(&:id), job["arguments"].first
    get admin_checks_path
    assert_select "button", "Approve 3 safe"
  end

  test "Previous and Next go on from the claims into the pending facts, as Checks lists them" do
    last_claim = waiting("Zulu Co")
    pending = DataQuality::Review.fact_kinds.flat_map { |kind| DataQuality::Review.pending_facts(kind:, limit: 100) }
    first_pending = pending.first
    back = admin_checks_path(category: "facts")

    get admin_fact_path(type: "Organization", id: last_claim.subject_id, from: "checks", back:)
    assert_select ".nd-itemnav", /1 of #{1 + pending.size}/
    assert_select ".nd-itemnav a[rel=next][href=?]", admin_fact_path(type: first_pending.type, id: first_pending.id, from: "checks", back:)

    get admin_fact_path(type: first_pending.type, id: first_pending.id, from: "checks", back:)
    assert_select ".nd-itemnav", /2 of #{1 + pending.size}/
  end

  test "Read and Same count today's match runs only" do
    travel_to Time.zone.parse("2026-10-15 12:00")
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.days.ago, finished_at: 2.days.ago,
      stats: { "candidates" => 219, "confirmed" => 219 })
    CrawlRun.create!(stage: "match", source_kind: "eia_generators", status: "succeeded", started_at: 1.hour.ago, finished_at: 1.hour.ago,
      stats: { "candidates" => 6, "confirmed" => 4 })

    get admin_checks_path

    assert_select ".nd-tile", /Read\s+6/
    assert_select ".nd-tile", /Same\s+4/
  end
end
