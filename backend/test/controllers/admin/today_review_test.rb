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

  def undo_token = flash[:undo].tap { |token| assert token, "an Undo is offered" }

  test "Undo a Reject: it's waiting again, as it was" do
    post admin_today_review_decide_path(candidate_id: @only_joy.id, decision: "reject")
    token = undo_token
    follow_redirect!
    assert_select ".nd-flash[role=status]", /Rejected\.\s*Undo/
    assert_select ".nd-flash form.nd-flash__undo button", "Undo"
    post admin_today_review_undo_path, params: { token: }

    assert_equal "Undone. It's waiting again.", flash[:notice]
    assert @only_joy.reload.status_matched?
    assert_nil @only_joy.reviewed_by
  end

  test "an Accept has no Undo: it may have published or changed a record, so it's taken back on the record" do
    post admin_today_review_decide_path(candidate_id: @both.id, decision: "accept")
    assert @both.reload.status_merged?, flash[:alert]
    assert_nil flash[:undo]
    assert_equal "Accepted. To take it back, change it on its record.", flash[:notice]
  end

  test "a Reject keeps the fact's notes, so Undo loses nothing" do
    @only_joy.update_columns(notes: "the page names it")
    post admin_today_review_decide_path(candidate_id: @only_joy.id, decision: "reject")
    assert_equal "the page names it", @only_joy.reload.notes
    post admin_today_review_undo_path, params: { token: undo_token }
    assert_equal [ "matched", "the page names it" ], [ @only_joy.reload.status, @only_joy.notes ]
  end

  test "a Reject that retired the record its fact proposed has no Undo" do
    proposed = Organization.create!(name: "Proposed Fission Co")
    claim = Candidate.create!(source: @source, kind: "organization", payload: { "name" => proposed.name }, quote: "q", crawl_run: @both.crawl_run,
      status: "matched", subject_type: "Organization", subject_id: proposed.id, proposed_subject: true, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    post admin_today_review_decide_path(candidate_id: claim.id, decision: "reject")
    assert claim.reload.status_rejected?
    assert_nil flash[:undo]
  end

  test "copies of one fact with different verdicts are separate rows; a fact's copies are never split across pages" do
    other = Source.create!(url: "https://www.doe.gov/test/split.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    unsure = Candidate.create!(source: other, kind: "organization", payload: @only_joy.payload, quote: "Also.", crawl_run: @only_joy.crawl_run,
      status: "needs_review", notes: "unsure", subject_type: "Organization", subject_id: @only_joy.subject_id, ai_recommendation: "needs_review", ai_source_sha256: "sha")
    review = TodayReview.new
    assert(review.rows("only_joy").none? { |row| row.candidate_ids.sort == [ @only_joy.id, unsure.id ].sort }, "different verdicts, different rows")

    stub_const(TodayReview, :PAGE, 1) do
      again = Candidate.create!(source: other, kind: "organization", payload: @only_joy.payload, quote: "Again.", crawl_run: @only_joy.crawl_run,
        status: "matched", subject_type: "Organization", subject_id: @only_joy.subject_id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
      first = TodayReview.new.rows("only_joy").first
      assert_equal [ again.id, @only_joy.id ].sort, first.candidate_ids.sort, "both copies on the first page"
    end
  end

  test "Undo works only while nothing else has changed it" do
    post admin_today_review_decide_path(candidate_id: @only_joy.id, decision: "reject")
    token = undo_token
    @only_joy.reload.update!(notes: "decided again elsewhere")

    post admin_today_review_undo_path, params: { token: }
    assert_equal "Can't undo this: it changed since, so it can't be undone here.", flash[:alert]
    assert @only_joy.reload.status_rejected?
  end

  test "the same fact from another page is one row, decided in one click" do
    other = Source.create!(url: "https://www.doe.gov/test/today-review.html", source_kind: "web_page", crawl_status: "ok", title: "DOE page", content_sha256: "sha")
    again = Candidate.create!(source: other, kind: "organization", payload: @only_joy.payload, quote: "Also listed.", crawl_run: @only_joy.crawl_run,
      status: "matched", subject_type: "Organization", subject_id: @only_joy.subject_id, ai_recommendation: "recommend_publish",
      ai_reason: "DOE lists it.", ai_confidence: 0.9, ai_source_sha256: "sha")

    get admin_today_review_path
    assert_select "h2", /Only Joy checked\s+2/
    assert_select "#fact-#{again.id}", /Also on 1 other page: nrc\.gov ↗\. One decision covers both\./
    assert_select "#fact-#{@only_joy.id}", 0

    post admin_today_review_decide_path(candidate_id: again.id, decision: "reject"), params: { same: [ again.id, @only_joy.id ] }
    assert again.reload.status_rejected?
    assert @only_joy.reload.status_rejected?

    post admin_today_review_undo_path, params: { token: undo_token }
    assert_equal "Undone. It's waiting again.", flash[:notice]
    assert again.reload.status_matched?
    assert @only_joy.reload.status_matched?
  end

  test "a new company several pages propose is one decision" do
    proposals = [ @source, Source.create!(url: "https://example.com/news", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha") ].map do |source|
      Candidate.create!(source:, kind: "organization", payload: { "name" => "Brand New Fission" }, quote: "Brand New Fission was founded.",
        crawl_run: @both.crawl_run, status: "needs_review", notes: "new company", ai_recommendation: "needs_review", ai_source_sha256: "sha")
    end

    get admin_today_review_path
    assert_select "li.nd-verdict", text: /Brand New Fission/, count: 1
    assert_select "li.nd-verdict", /Brand New Fission.*One decision covers both/m
  end

  test "a new company proposed with different values on two pages is two decisions" do
    [ [ @source, "brandnew.com" ], [ Source.create!(url: "https://example.com/news2", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha"), "other.com" ] ].each do |source, domain|
      Candidate.create!(source:, kind: "organization", payload: { "name" => "Brand New Fission", "domain" => domain }, quote: "Brand New Fission was founded.",
        crawl_run: @both.crawl_run, status: "needs_review", notes: "new company", ai_recommendation: "needs_review", ai_source_sha256: "sha")
    end
    get admin_today_review_path
    assert_select "li.nd-verdict", text: /Brand New Fission/, count: 2
  end

  test "a grouped Undo restores every copy or none: one changed since, nothing is undone" do
    other = Source.create!(url: "https://www.doe.gov/test/undo.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    again = Candidate.create!(source: other, kind: "organization", payload: @only_joy.payload, quote: "Also.", crawl_run: @only_joy.crawl_run,
      status: "matched", subject_type: "Organization", subject_id: @only_joy.subject_id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    post admin_today_review_decide_path(candidate_id: again.id, decision: "reject"), params: { same: [ again.id, @only_joy.id ] }
    token = undo_token
    @only_joy.reload.update!(notes: "changed elsewhere")

    post admin_today_review_undo_path, params: { token: }
    assert_match "it changed since", flash[:alert]
    assert again.reload.status_rejected?
    assert @only_joy.reload.status_rejected?
  end

  test "a fact that only restates what the site shows offers one action: Close, already on the site" do
    page = Source.create!(url: "https://example.com/restated", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha",
      content_text: "Agreed Fission Co holds a license.")
    company = Organization.find(@both.subject_id)
    company.verify!(by: "human:tosin")
    Evidence.create!(subject: company, source: page, quote: @both.quote, found_by: "human")
    same = Candidate.create!(source: page, kind: "organization", payload: @both.payload, quote: @both.quote,
      crawl_run: @both.crawl_run, status: "matched", subject_type: "Organization", subject_id: company.id, ai_recommendation: "recommend_publish",
      ai_reason: "Listed.", ai_source_sha256: "sha")
    assert_includes DataQuality::Review.restating_ids([ same.id ], by: "human:tosin"), same.id, DataQuality::Review.confirm_identical([ same.id ], by: "human:tosin", dry_run: true).map(&:errors).inspect

    get admin_today_review_path
    assert_select "#fact-#{same.id}", /It says what the site already shows\. Closing notes that in the history and changes nothing live\./
    assert_select "#fact-#{same.id} button", "Close: already on the site"
    assert_select "#fact-#{same.id} button", text: "Reject", count: 0

    post admin_today_review_decide_path(candidate_id: same.id, decision: "close")
    assert_equal "Closed. Nothing on the site changed.", flash[:notice]
    assert_equal "confirmed", same.reload.status
    assert_equal "verified", company.reload.verification_status
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

  test "a fact sent back to review isn't shown as Joy's accept, even with an old accept on it" do
    @only_joy.update_columns(status: "needs_review", notes: "withdrawn: the source no longer lists it")
    get admin_today_review_path
    assert_select "#fact-#{@only_joy.id} .nd-tag", text: "Joy: check it"
  end

  test "Undo is refused once the record its fact was about has been decided since" do
    post admin_today_review_decide_path(candidate_id: @only_joy.id, decision: "reject")
    token = undo_token
    Organization.find(@only_joy.subject_id).tap { |c| c.update_columns(verification_status: "rejected", verified_by: "human:tosin") }
    post admin_today_review_undo_path, params: { token: }
    assert_match "the record it was about was decided since", flash[:alert]
    assert @only_joy.reload.status_rejected?
  end

  test "Undo is refused after a merge moved the fact to another record" do
    post admin_today_review_decide_path(candidate_id: @only_joy.id, decision: "reject")
    token = undo_token
    kept = Organization.create!(name: "Kept Fission Co")
    Candidate.where(id: @only_joy.id).update_all(subject_id: kept.id) # as a merge repoints claims
    post admin_today_review_undo_path, params: { token: }
    assert_match "it changed since", flash[:alert]
  end

  test "unattached plants with the same name aren't grouped; only a new company's proposals are" do
    a, b = 2.times.map do |i|
      Candidate.create!(source: @source, kind: "facility", payload: { "name" => "Twin Point 1", "nrc_docket" => "0500088#{i}" }, quote: "q",
        crawl_run: @both.crawl_run, status: "needs_review", notes: "unsure", ai_recommendation: "needs_review", ai_source_sha256: "sha")
    end
    rows = TodayReview.new.rows("only_joy")
    assert(rows.none? { |row| (row.candidate_ids & [ a.id, b.id ]).size == 2 })
  end

  test "the shortcut accepts every copy of an agreed fact, not just the first" do
    other = Source.create!(url: "https://www.doe.gov/test/copy.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    copy = Candidate.create!(source: other, kind: "organization", payload: @both.payload, quote: "Agreed Fission Co holds a license.", crawl_run: @both.crawl_run,
      status: "matched", subject_type: "Organization", subject_id: @both.subject_id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    DataQuality::Recommendations.record("#{copy.id} approve: named on the DOE page", by: "human:tosin")
    review = TodayReview.new
    assert_equal [ copy.id, @both.id ].sort, review.rows("agree").sole.candidate_ids.sort

    post admin_today_review_agreed_path, params: { shown_set: review.fingerprint }
    assert @both.reload.status_merged?, flash[:alert]
    assert copy.reload.status_merged?, flash[:alert]
  end

  test "a copy whose recommendation changes after the page loaded isn't approved with its fact" do
    other = Source.create!(url: "https://www.doe.gov/test/race.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    copy = Candidate.create!(source: other, kind: "organization", payload: @both.payload, quote: "Agreed Fission Co holds a license.", crawl_run: @both.crawl_run,
      status: "matched", subject_type: "Organization", subject_id: @both.subject_id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    DataQuality::Recommendations.record("#{copy.id} approve: named on the DOE page", by: "human:tosin")
    review = TodayReview.new
    shown = review.fingerprint
    first, second = review.rows("agree").sole.then { |row| [ row.candidate_id, (row.candidate_ids - [ row.candidate_id ]).sole ] }

    accept = DataQuality::Recommendations.method(:accept)
    DataQuality::Recommendations.define_singleton_method(:accept) do |items, **options|
      accept.call(items, **options).tap { Candidate.where(id: second).update_all(dq_recommendation: "reject", dq_reason: "changed meanwhile") }
    end
    begin
      post admin_today_review_agreed_path, params: { shown_set: shown }
    ensure
      DataQuality::Recommendations.define_singleton_method(:accept, accept)
    end
    assert Candidate.find(first).status_merged?
    assert Candidate.find(second).status_matched?, "left waiting"
    assert_match "changed after the page loaded", flash[:alert]
  end

  test "an edit to the record between the first copy and the next isn't overwritten: the next copy waits" do
    other = Source.create!(url: "https://www.doe.gov/test/edit.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    copy = Candidate.create!(source: other, kind: "organization", payload: @both.payload, quote: "Agreed Fission Co holds a license.", crawl_run: @both.crawl_run,
      status: "matched", subject_type: "Organization", subject_id: @both.subject_id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    DataQuality::Recommendations.record("#{copy.id} approve: named on the DOE page", by: "human:tosin")
    review = TodayReview.new
    shown = review.fingerprint
    first, second = review.rows("agree").sole.then { |row| [ row.candidate_id, (row.candidate_ids - [ row.candidate_id ]).sole ] }

    approve = DataQuality::Review.method(:approve)
    DataQuality::Review.define_singleton_method(:approve) do |ids, **options|
      Organization.where(id: Candidate.find(first).subject_id).update_all(description: "Edited by a person meanwhile.") if ids == [ second ]
      approve.call(ids, **options)
    end
    begin
      post admin_today_review_agreed_path, params: { shown_set: shown }
    ensure
      DataQuality::Review.define_singleton_method(:approve, approve)
    end
    assert Candidate.find(first).status_merged?
    assert Candidate.find(second).status_matched?, "left waiting"
    assert_match "its record changed after the first page's copy was accepted", flash[:alert]
  end
end
