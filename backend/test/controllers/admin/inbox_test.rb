require "test_helper"

# Today as Tosin's inbox (#548): what's new, changes to his decisions, a
# week of decisions with Undo for a No, and nothing Data Quality settles.
class Admin::InboxTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    @page = Source.create!(url: "https://www.nrc.gov/test/inbox.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha")
    first = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
    Candidate.create!(source: @page, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    @new_co = Organization.create!(name: "Bluefield Fission", verification_status: "pending")
    @create = claim({ "name" => "Bluefield Fission", "hq_city" => "Austin", "hq_state" => "TX" }, subject: @new_co, proposed_subject: true)
    @decided = Organization.create!(name: "Rockville Nuclear", hq_city: "Bethesda", verification_status: "verified", verified_by: "human:tosin")
    @decided.aliases.create!(alias: "Rockville Nuclear")
    @change = claim({ "name" => "Rockville Nuclear", "hq_city" => "Rockville" }, subject: @decided)
    @settle = Candidate.create!(source: @page, crawl_run: @run, kind: "organization", payload: { "name" => "Who Knows Co" }, quote: "q",
      status: "needs_review", notes: %(no exact match for "Who Knows Co"))
  end

  def claim(payload, subject:, **options)
    Candidate.create!(source: @page, crawl_run: @run, kind: "organization", payload:, quote: "q", status: "matched",
      subject_type: "Organization", subject_id: subject.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha", **options)
  end

  test "Today shows what's new and changes to his decisions, never Data Quality's to settle" do
    get admin_inbox_path
    assert_response :success
    assert_select "p", /1 to decide\. Nothing goes live until you say yes\./
    assert_select "#inbox-item-#{@create.id}", /Bluefield Fission: a company in Austin, TX\./
    assert_select "#inbox-item-#{@create.id} button", "Create"
    assert_select "#inbox-item-#{@change.id}", 0, "a change stays on Checks"
    assert_select "#inbox-item-#{@settle.id}", 0
    assert_select "nav a[href=?]", admin_inbox_path, text: /Today\s*1/
  end

  test "Create publishes; No says no and can be undone from Recently decided" do
    post admin_inbox_decide_path(@create.id, "yes"), params: { ids: [ @create.id ] }
    assert @new_co.reload.verified?
    post admin_inbox_decide_path(@change.id, "no"), params: { ids: [ @change.id ] }
    assert @change.reload.status_rejected?

    get admin_inbox_path
    assert_select "#recent-#{@change.id}", /Said no to Rockville Nuclear/
    post admin_inbox_undo_path, params: { token: flash[:undo] }
    assert_equal "matched", @change.reload.status, "back as it was before the No"
    assert_equal @decided.id, @change.subject_id
  end

  test "Yes to all takes only what Data Quality checked, each checked again" do
    DataQuality::Recommendations.record("#{@create.id} approve: named on the NRC page", by: "human:dq")
    get admin_inbox_path
    assert_select ".nd-panel", 0, "one checked item needs no batch button"
    other = Organization.create!(name: "Second Fission", verification_status: "pending")
    second = claim({ "name" => "Second Fission" }, subject: other, proposed_subject: true)
    DataQuality::Recommendations.record("#{second.id} approve: named on the NRC page", by: "human:dq")
    get admin_inbox_path
    assert_select ".nd-panel", /Data Quality checked 2 of these 2\./
    assert_select "#inbox-item-#{second.id} .type-small", /“q”/, "a name-only company shows its quote"
    shown = css_select("form[action='#{admin_inbox_yes_all_path}'] input[name=shown]").first["value"]
    DataQuality::Recommendations.record("#{second.id} approve: named on the NRC page again", by: "human:dq")
    post admin_inbox_yes_all_path, params: { shown: }
    assert_match "The list changed", flash[:alert], "a call changed after the page loaded"
    assert_not @new_co.reload.verified?
    get admin_inbox_path
    shown = css_select("form[action='#{admin_inbox_yes_all_path}'] input[name=shown]").first["value"]
    post admin_inbox_yes_all_path, params: { shown: }
    assert @new_co.reload.verified?
    assert other.reload.verified?
    assert_match "2 items live", flash[:notice]
  end

  test "a No on a new company keeps it in Leads" do
    post admin_inbox_decide_path(@create.id, "no"), params: { ids: [ @create.id ] }
    assert @create.reload.status_rejected?
    lead = Lead.find_by!(kind: "company", normalized_name: "bluefield fission")
    assert lead.status_new?
    assert_equal "Said no in Today", lead.sources.sole["label"]
    assert_equal "Said no. It's kept in Leads.", flash[:notice]
  end
end
