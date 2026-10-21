require "test_helper"

# Today's step 3 (#373 part C): each fact with Joy's and Aminah's verdicts,
# in three runs, decided here; the shortcut takes the ones they agree on.
class Admin::TodayReviewTest < ActionDispatch::IntegrationTest
  BANNED = /\b(claims?|verifiers?|candidates?|fingerprints?|safe class(es)?|S1)\b/i

  setup do
    sign_in_as users(:admin)
    @source = Source.create!(url: "https://www.nrc.gov/test/today-review.html", source_kind: "nrc_reactor_list", crawl_status: "ok",
      title: "NRC test page", content_sha256: "sha")
    run = CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.days.ago)
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.day.ago) # not a first batch
    @both = fact("Agreed Fission Co", joy: "recommend_publish", run:)
    @only_joy = fact("Unlisted Fission Co", joy: "recommend_publish", run:)
    @differ = fact("Unsure Fission Co", joy: "needs_review", run:)
    DataQuality::Recommendations.record("#{@both.id} approve: named on the NRC page\n#{@differ.id} approve: the NRC page names it", by: "human:tosin")
  end

  def fact(name, joy:, run:)
    company = Organization.create!(name:)
    Candidate.create!(source: @source, kind: "organization", payload: { "name" => name }, quote: "#{name} holds a license.", crawl_run: run,
      status: (joy == "needs_review" ? "needs_review" : "matched"), subject_type: "Organization", subject_id: company.id,
      ai_recommendation: joy, ai_reason: "The NRC page lists #{name}.", ai_confidence: 0.9, ai_source_sha256: "sha")
  end

  test "three runs, each fact with both verdicts and why; the filled button follows them only when they agree" do
    get admin_today_review_path

    assert_select "h2", /Joy and Aminah agree\s+1/
    assert_select "h2", /Only Joy checked\s+1/
    assert_select "h2", /Joy and Aminah disagree\s+1/
    assert_select "#fact-#{@both.id} .nd-tag", text: "✓ Joy: accept"
    assert_select "#fact-#{@both.id} .nd-tag", text: "✓ Aminah: accept"
    assert_select "#fact-#{@only_joy.id} .nd-tag", text: "Aminah: not reviewed"
    assert_select "#fact-#{@differ.id} .nd-tag", text: "Joy: check it"
    assert_select "#fact-#{@both.id} details", /Joy: The NRC page lists Agreed Fission Co.*Aminah: named on the NRC page.*nrc\.gov/m
    assert_select "#fact-#{@both.id} .nd-btn--primary", "Accept"
    assert_select "#fact-#{@differ.id} .nd-btn--primary", 0
    assert_select "#fact-#{@only_joy.id} .nd-btn--primary", 0
    assert_no_match BANNED, css_select("main").text.squish
  end

  test "the shortcut accepts only the facts they agree on" do
    get admin_today_review_path
    assert_select "button", "Do the 1 they agree on"

    post admin_today_review_agreed_path, params: { shown_set: TodayReview.new.fingerprint }
    assert_equal "Accepted 1 fact.", flash[:notice]
    assert @both.reload.status_merged?
    assert @only_joy.reload.status_matched?
    assert @differ.reload.status_needs_review?
  end

  test "Accept or Reject one fact, as the admin" do
    post admin_today_review_decide_path(candidate_id: @only_joy.id, decision: "reject")
    assert_equal "Rejected.", flash[:notice]
    assert_equal "human:tosin", @only_joy.reload.reviewed_by
    assert @only_joy.status_rejected?

    post admin_today_review_decide_path(candidate_id: @differ.id, decision: "accept")
    assert @differ.reload.status_merged?, flash[:alert]
  end

  test "step 3 on Today sums up the verdicts and opens the review" do
    post admin_today_step_path("crawl")
    post admin_today_step_path("list"), params: { note: "no_list" }
    follow_redirect!

    # "No list from Aminah today": her earlier calls don't count today.
    assert_select "#step-review", /3 facts\. Joy and Aminah agree on 0; 0 have different verdicts; Aminah didn't see 3\./
    assert_select "#step-review a[href=?]", admin_today_review_path, text: "Start reviewing ›"
  end

  test "step 2 says what Aminah's list is for" do
    post admin_today_step_path("crawl")
    follow_redirect!
    assert_select "#step-list", /Aminah's list is her own check of the facts Joy looked at: for each one she says accept or reject, and why\. Adding it decides nothing/
  end

  test "the shortcut takes only the list the page showed: a change since refuses it" do
    shown = TodayReview.new.fingerprint
    DataQuality::Recommendations.record("#{@only_joy.id} approve: listed on the NRC page", by: "human:tosin")

    post admin_today_review_agreed_path, params: { shown_set: shown }
    assert_match "The list changed since you opened it", flash[:alert]
    assert @both.reload.status_matched?
  end

  test "a fact the shortcut can't publish says why, by number" do
    stopped = DataQuality::Review::Result.new(candidate_id: @both.id, ref: nil, errors: [ "a person decided this company today" ])
    accept = DataQuality::Recommendations.method(:accept)
    DataQuality::Recommendations.define_singleton_method(:accept) { |*, **| [ stopped ] }
    begin
      post admin_today_review_agreed_path, params: { shown_set: TodayReview.new.fingerprint }
    ensure
      DataQuality::Recommendations.define_singleton_method(:accept, accept)
    end
    assert_equal "1 fact can't be published yet, so it stays below: ##{@both.id}: a person decided this company today", flash[:alert]
  end

  test "newest first, a page per run, with Show more and the full count" do
    stub_const(TodayReview, :PAGE, 1) do
      newer = fact("Newer Fission Co", joy: "recommend_publish", run: @both.crawl_run)
      get admin_today_review_path
      assert_select "h2", /Only Joy checked\s+2/
      assert_select "#run-only_joy ~ ol li", 1
      assert_select "#fact-#{newer.id}"
      assert_select "a[href*=?]", "shown%5Bonly_joy%5D=2", text: "Show 1 more"

      get admin_today_review_path(shown: { only_joy: 2 })
      assert_select "#fact-#{@only_joy.id}"
    end
  end

  test "facts waiting without a check are counted and linked, so the page never says nothing waits while they do" do
    Candidate.delete_all
    role = Role.create!(key: "fuel", name: "Fuel")
    company = Organization.create!(name: "Hand Added Co", verification_status: "verified", verified_by: "human:tosin")
    fact = OrganizationRole.create!(organization: company, role:, verification_status: "pending")
    Evidence.create!(subject: fact, source: @source, quote: "Hand Added Co makes fuel.", found_by: "human")

    get admin_today_review_path
    assert_select "a[href=?]", admin_pending_facts_path, text: /Decide (it|them)/
    assert_no_match "Nothing waiting", response.body
  end

  test "a fact that changes a checked value says what accepting replaces, and offers Keep" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", verification_status: "verified", verified_by: "human:tosin")
    changed = Candidate.create!(source: @source, kind: "facility", quote: "q", status: "needs_review", notes: "unsure", ai_recommendation: "needs_review",
      crawl_run: @both.crawl_run, subject_type: "Facility", subject_id: unit.id, payload: { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })

    get admin_today_review_path
    assert_select "#fact-#{changed.id}", /Accepting replaces the checked state \(NJ → DE\)/
    assert_select "#fact-#{changed.id} button", "Keep"
  end

  test "with no list from Aminah today, her earlier calls show as not reviewed and the shortcut takes none" do
    post admin_today_step_path("crawl")
    post admin_today_step_path("list"), params: { note: "no_list" }
    get admin_today_review_path
    assert_select "#fact-#{@both.id} .nd-tag", text: "Aminah: not reviewed"
    assert_select "#fact-#{@both.id} details", /Aminah: Aminah didn't review this one\./
    assert_select "button", text: /they agree on/, count: 0
    assert_empty TodayReview.new.agreed_items
  end

  test "a list's problems say fact, not claim" do
    post admin_today_step_path("crawl")
    post admin_today_list_path, params: { list: "999999 approve: not a real one\nnonsense" }
    assert_no_match(/\bclaims?\b/i, css_select(".nd-alert").text)
  end
end
