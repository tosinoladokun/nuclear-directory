require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# Checks (#201) and the decisions behind it (#86): claims listed with their
# label, subject and value, approved, rejected, edited or approved all
# through the real Review API and directory.
class Admin::CandidatesControllerTest < ActionDispatch::IntegrationTest
  class Recommend
    def call(candidate) = DataQuality::Verdict.new(outcome: :publish, confidence: 0.92, reason: "The row names #{candidate.payload['name']}.")
  end

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/admin.html", source_kind: "dummy", crawl_status: "ok", title: "NRC test page")
  end

  def candidate(kind, payload, quote: "a quote") = Candidate.create!(source: @source, kind:, payload:, quote:)

  def match_and_verify
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "match")
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "verify", verifier: Recommend.new)
  end

  test "needs a signed-in admin" do
    get admin_checks_path
    assert_redirected_to new_session_path

    post approve_admin_candidates_path, params: { candidate_id: 1 }
    assert_redirected_to new_session_path
  end

  test "Checks lists a recommended claim as one row: label, subject, buttons, and its quote, source and reason behind Details" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    match_and_verify
    sign_in_as users(:admin)

    get admin_checks_path

    assert_response :success
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_select "#claim-#{c.id}" do
      assert_select ".type-kicker", "New company · nrc.gov"
      assert_select ".type-subject a[href=?]", admin_fact_path(type: "Organization", id: c.reload.subject_id, from: "checks", back: "/admin/checks", claim: c.id), text: "Imaginary Fission Co"
      assert_select "details .nd-quote", "“a quote”"
      assert_select "details a[href=?]", @source.url, text: /NRC test page/
      assert_select "details", /Verifier recommends publishing.*92% sure.*The row names Imaginary Fission Co/m
      assert_select "button[name=candidate_id][value=?]", c.id.to_s, text: "Approve"
      assert_select "button[formaction=?]", reject_admin_candidates_path, text: "Reject"
      assert_select "a[href=?]", edit_admin_candidate_path(c, back: "/admin/checks"), text: "Edit"
    end
    waiting = 1 + DataQuality::Review.pending_count # the fixtures' pending facts are waiting too
    assert_select ".nd-fchip[aria-current=page]", /All\s+#{waiting}/
    # Today's count: the facts waiting, plus step 4's correction requests (none here).
    assert_select ".nd-shell__nav a[aria-current=page]", /Today\s+#{waiting}/
    assert_select "h2", /Waiting\s+#{waiting}/
  end

  test "the old queue address leads to Checks" do
    sign_in_as users(:admin)
    get admin_candidates_path(queue: "needs_review")
    assert_redirected_to admin_checks_path
  end

  test "approving one claim publishes it as the signed-in person, back on Checks with its chip" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    match_and_verify
    sign_in_as users(:admin)

    post approve_admin_candidates_path(category: "facts"), params: { candidate_id: c.id, candidate_ids: [ c.id + 1000 ] }

    assert_redirected_to admin_checks_path(category: "facts")
    assert_equal "Approved 1 item.", flash[:notice]
    organization = Organization.find(c.reload.subject_id)
    assert_equal [ "verified", "human:tosin" ], [ organization.verification_status, organization.verified_by ]
  end

  test "approving several claims at once, and nothing when none is given" do
    a = candidate("organization", { "name" => "Alpha Fission Co" })
    b = candidate("organization", { "name" => "Beta Fission Co" })
    match_and_verify
    sign_in_as users(:admin)

    post approve_admin_candidates_path, params: {}
    assert_equal "Select at least one claim to approve.", flash[:alert]

    post approve_admin_candidates_path, params: { candidate_ids: [ a.id, b.id ] }

    assert_redirected_to admin_checks_path
    assert_equal "Approved 2 items.", flash[:notice]
    assert [ a, b ].all? { |x| x.reload.status_merged? }
  end

  test "bulk approval is for recommended claims only" do
    recommended = candidate("organization", { "name" => "Imaginary Fission Co" })
    unsure = candidate("organization", { "name" => "Quoted Co" }, quote: "not in the source")
    @source.update!(content_text: "Imaginary Fission Co appears here, and a quote too: a quote")
    match_and_verify
    assert unsure.reload.status_needs_review?
    sign_in_as users(:admin)

    post approve_admin_candidates_path, params: { candidate_ids: [ recommended.id, unsure.id ] }

    assert_equal "Approved 1 item.", flash[:notice]
    assert_match "Claim #{unsure.id}: it isn't recommended, so approve it on its own", flash[:alert]
    assert unsure.reload.status_needs_review?

    post approve_admin_candidates_path, params: { candidate_id: unsure.id }
    assert unsure.reload.status_merged?, "on its own, it can be approved"
  end

  test "Approve N safe: every recommended claim on every page, in the background, as the signed-in person (#188)" do
    stub_const(Admin::ChecksController, :PAGE, 2) do
      claims = %w[Alpha Beta Gamma].map { |name| candidate("organization", { "name" => "#{name} Fission Co" }) }
      unsure = candidate("organization", { "name" => "Quoted Co" }, quote: "not in the source")
      @source.update!(content_text: "Alpha Fission Co Beta Fission Co Gamma Fission Co a quote")
      match_and_verify
      sign_in_as users(:admin)

      get admin_checks_path
      assert_select ".nd-waits > li", 2, "one page"
      assert_select "a", text: "Next 2"
      assert_select "form[action=?] button", approve_all_admin_candidates_path, "Approve 3 safe"

      shown = css_select("form[action='#{approve_all_admin_candidates_path}'] input[name=shown]").first["value"]
      assert_match "all 3 recommended claims?", css_select("form[data-turbo-confirm]").first["data-turbo-confirm"]

      perform_enqueued_jobs { post approve_all_admin_candidates_path, params: { shown: } }

      assert_redirected_to admin_checks_path
      assert_match "Approving 3 recommended claims", flash[:notice]
      claims.each do |claim|
        assert claim.reload.status_merged?, claim.payload["name"]
        assert_equal "human:tosin", Organization.find(claim.subject_id).verified_by
      end
      assert unsure.reload.status_needs_review?, "a claim needing review is never approved in bulk"
    end
  end

  test "approve all approves only what was shown: if the list changed, nothing is approved" do
    candidate("organization", { "name" => "Alpha Fission Co" })
    match_and_verify
    sign_in_as users(:admin)
    get admin_checks_path
    shown = css_select("input[name=shown]").first["value"]

    late = candidate("organization", { "name" => "Late Fission Co" }) # recommended after the page loaded
    match_and_verify

    assert_no_enqueued_jobs only: DataQuality::ApproveAllJob do
      post approve_all_admin_candidates_path, params: { shown: }
    end
    assert_match "The queue changed since you opened it", flash[:alert]
    assert_not late.reload.status_merged?
  end

  # Makes the next `n` approvals collide with a merge, as the database would
  # stop one of two transactions locking the same rows (#325).
  module Collide
    mattr_accessor :left, default: 0

    private

    def approve_one(*, **)
      return super unless Collide.left.positive?

      Collide.left -= 1
      raise ActiveRecord::Deadlocked, "deadlock detected"
    end
  end
  DataQuality::Review.singleton_class.prepend(Collide)

  test "an approval that collides with a merge approves nothing and says to try again (#325)" do
    c = candidate("organization", { "name" => "Busy Fission Co" })
    match_and_verify
    sign_in_as users(:admin)

    Collide.left = 1
    post approve_admin_candidates_path, params: { candidate_id: c.id }

    assert_response :see_other
    assert_match "someone was merging this just then; try again", flash[:alert]
    assert_not c.reload.status_merged?
  ensure
    Collide.left = 0
  end

  test "approve all tries a batch again when it collides with a merge, then approves it (#325)" do
    c = candidate("organization", { "name" => "Retry Fission Co" })
    match_and_verify

    Collide.left = 1
    DataQuality::ApproveAllJob.perform_now([ c.id ], by: users(:admin).actor)

    assert c.reload.status_merged?
  ensure
    Collide.left = 0
  end

  test "approve all keeps to its filters, and says when nothing matches" do
    candidate("organization", { "name" => "Alpha Fission Co" })
    match_and_verify
    sign_in_as users(:admin)

    assert_no_enqueued_jobs only: DataQuality::ApproveAllJob do
      post approve_all_admin_candidates_path(reason: "no such reason")
    end
    assert_equal "Nothing to approve: no recommended claims match these filters.", flash[:alert]
  end

  test "rejecting a claim with a reason" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    match_and_verify
    sign_in_as users(:admin)

    post reject_admin_candidates_path, params: { candidate_id: c.id, reasons: { c.id.to_s => "Not a real company" } }

    assert_equal "Rejected 1 item.", flash[:notice]
    assert_equal [ "rejected", "Not a real company", "human:tosin" ], [ c.reload.status, c.notes, c.reviewed_by ]
  end

  test "a claim that disagrees with a human-verified value is Changed: old → new, and Keep rejects it" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ")
    unit.verify!(by: "human:tosin")
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    match_and_verify
    sign_in_as users(:admin)

    get admin_checks_path(category: "changed")

    assert_select ".nd-fchip[aria-current=page]", /Changed\s+1/
    assert_select "#claim-#{c.id}" do
      assert_select ".type-kicker", "Changed · nrc.gov"
      assert_select ".type-subject", "Hope Creek 1 · State"
      assert_select ".type-change", "NJ → DE"
      assert_select "details", /Human-verified state is NJ; this source says DE/
      assert_select "button[formaction=?]", reject_admin_candidates_path(category: "changed"), text: "Keep"
    end

    post reject_admin_candidates_path(category: "changed"), params: { candidate_id: c.id }
    assert_redirected_to admin_checks_path(category: "changed")
    assert_equal "NJ", unit.reload.state
  end

  test "edit, then approve: publishes the edited value; link ends can't be posted" do
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    match_and_verify
    sign_in_as users(:admin)

    get edit_admin_candidate_path(c, category: "facts")
    assert_select "input[name=?][value=?]", "values[state]", "DE"
    assert_select ".nd-crumbs li a[href=?]", admin_checks_path(category: "facts"), text: "Checks"
    assert_select ".nd-crumbs__back", "‹ Checks"

    patch admin_candidate_path(c), params: { values: { state: "NJ", facility: "Somewhere else" }, note: "NRC lists the nearby city's state" }

    assert_redirected_to admin_checks_path
    unit = Facility.find(c.reload.subject_id)
    assert_equal [ "NJ", "human:tosin" ], [ unit.state, unit.verified_by ]
    assert_equal "NRC lists the nearby city's state", Directory::Lookup.verification_history(type: "Facility", id: unit.id).first.reason
  end

  test "a company role's role shows read-only, and approving it with no changes works" do
    vendor = Role.create!(key: "reactor_vendor", name: "Reactor vendor")
    c = candidate("organization_role", { "organization" => { "name" => "TerraPower" }, "role" => "reactor_vendor" })
    c.update!(status: "matched", subject: OrganizationRole.create!(organization: organizations(:terrapower), role: vendor))
    sign_in_as users(:admin)

    get edit_admin_candidate_path(c)
    assert_select "input[name=?]", "values[role]", count: 0
    assert_select ".nd-field", /Role\s+Reactor vendor\s+Can.t be edited here/

    # The form as the browser sends it, and as an older page did: with the role, unchanged.
    patch admin_candidate_path(c), params: { values: { role: "utility" } }
    assert_response :unprocessable_content
    assert_select ".nd-alert", /can't edit role here/i
    assert c.reload.status_matched?, "a changed role is refused, not dropped"
    assert_select ".nd-field", /Role\s+Reactor vendor\s+Can.t be edited here/, "the page shows the claim's role, not the refused one"

    patch admin_candidate_path(c), params: { values: { role: "reactor_vendor" } }
    assert c.reload.status_merged?, [ response.status, flash[:alert], css_select(".nd-alert").text.squish ].inspect
    assert_nil flash[:alert]
  end

  test "a failed edit shows the error and keeps the form" do
    c = candidate("organization", { "name" => "Imaginary Fission Co", "founded_year" => "1990" })
    match_and_verify
    sign_in_as users(:admin)

    patch admin_candidate_path(c), params: { values: { founded_year: "not a year" } }

    assert_response :unprocessable_content
    assert_select ".nd-alert[role=alert]", /Not approved. Fix this and approve again/
    assert c.reload.status_matched?, "nothing approved"
  end
end
