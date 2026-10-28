require "test_helper"

# Today as Tosin's inbox (#548): what's new, changes to his decisions, a
# week of decisions with Undo for a No, and nothing Data Quality settles.
class Admin::InboxTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    # The claims quote "q", which the page's stored text contains (Yes to all checks it).
    @page = Source.create!(url: "https://www.nrc.gov/test/inbox.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha", content_text: "q")
    first = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
    Candidate.create!(source: @page, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    @new_co = give_sourced_role(Organization.create!(name: "Bluefield Fission", verification_status: "pending"))
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
    # Its two claims, plus the fixtures' pending records with no open claim.
    total = 2 + OwnerInbox.new.records.size
    assert_select "p", /#{total} to decide\. Nothing goes live until you say yes\./
    assert_select "#inbox-item-#{@create.id}", /Bluefield Fission: a company in Austin, TX\./
    assert_select "#inbox-item-#{@create.id} button", "Create"
    assert_select "#inbox-item-#{@change.id}", /Rockville Nuclear · Headquarters city:\s*Bethesda\s*→\s*Rockville/
    assert_select "#inbox-item-#{@change.id} button", /Keep what I decided/
    assert_select "#inbox-item-#{@settle.id}", 0
    assert_select "nav a[href=?]", admin_inbox_path, text: /Today\s*#{total}/
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
    other = give_sourced_role(Organization.create!(name: "Second Fission", verification_status: "pending"))
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

  test "Data Quality's own approve counts for Yes to all even where the checker doubted; the row shows both" do
    @page.update!(content_text: "Bluefield Fission, of Austin, Texas. q")
    @create.update!(status: "needs_review", ai_recommendation: "needs_review", ai_reason: "Not sure the company is nuclear", quote: "Bluefield Fission, of Austin, Texas.")
    DataQuality::Recommendations.record("#{@create.id} approve: Its NRC license names it", by: "human:dq")
    other = give_sourced_role(Organization.create!(name: "Second Doubted Co", verification_status: "pending"))
    second = claim({ "name" => "Second Doubted Co" }, subject: other, proposed_subject: true)
    DataQuality::Recommendations.record("#{second.id} approve: Named on the NRC page", by: "human:dq")
    get admin_inbox_path
    assert_select ".nd-panel", /Data Quality checked 2 of these 2\./
    assert_select "#inbox-item-#{@create.id}", /The checker wasn't sure: Not sure the company is nuclear/
    assert_select "#inbox-item-#{@create.id}", /Data Quality checked it: Its NRC license names it/
    shown = css_select("form[action='#{admin_inbox_yes_all_path}'] input[name=shown]").first["value"]
    post admin_inbox_yes_all_path, params: { shown: }
    assert @new_co.reload.verified?, flash[:alert].to_s
  end

  test "a claim the checker contradicted with a different value never counts for Yes to all, whatever Data Quality says" do
    @create.update!(status: "needs_review", ai_recommendation: "needs_review",
      ai_reason: "#{DataQuality::Verifiers::Agent::CONTRADICTS} (the source gives Dallas): it says Dallas")
    DataQuality::Recommendations.record("#{@create.id} approve: I read it as Austin", by: "human:dq")
    get admin_inbox_path
    assert_select ".nd-panel", 0, "nothing for the button: the only approve is contradicted"
    item = DataQuality::Review.items([ @create.id ]).sole
    result = DataQuality::Recommendations.accept([ DataQuality::Recommendations::Item.new(candidate_id: @create.id, call: "approve", reason: "I read it as Austin",
      snapshot: @create.reload.dq_payload_sha256, claim: nil, subject_type: item.subject_type, subject_id: item.subject_id, why: nil, waiting: true) ],
      by: "human:tosin", first_hand: true).sole
    assert_not result.ok?
    assert_not @new_co.reload.verified?
  end

  test "a claim with no quote never counts for Yes to all, even with Data Quality's approve" do
    @page.update!(content_text: nil)
    @create.update_columns(quote: "")
    DataQuality::Recommendations.record("#{@create.id} approve: looks right", by: "human:dq")
    entry = OwnerInbox.new.sections["new_record"].find { |e| e.item.candidate_id == @create.id }
    assert_not entry.checked
    item = DataQuality::Recommendations::Item.new(candidate_id: @create.id, call: "approve", reason: "looks right", snapshot: @create.reload.dq_payload_sha256,
      claim: nil, subject_type: "Organization", subject_id: @new_co.id, why: nil, waiting: true)
    assert_not DataQuality::Recommendations.accept([ item ], by: "human:tosin", first_hand: true).sole.ok?
    assert_not @new_co.reload.verified?
  end

  test "a pending company or plant with no open claim is in Today; Create publishes it, No rejects it" do
    src = Source.create!(url: "https://www.nrc.gov/test/seeded.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "s")
    seeded = give_sourced_role(Organization.create!(name: "Seeded Pending Co", verification_status: "pending"))
    no_role = Organization.create!(name: "Roleless Pending Co", verification_status: "pending")
    Evidence.create!(subject: no_role, source: Source.create!(url: "https://example.com/roleless", source_kind: "web_page", crawl_status: "ok", content_sha256: "x"),
      quote: "Roleless Pending Co.", found_by: "human")
    Evidence.create!(subject: seeded, source: src, quote: "Seeded Pending Co builds reactors.", found_by: "human")
    plant = Facility.create!(name: "PULSTAR Reactor", verification_status: "pending")
    Evidence.create!(subject: plant, source: src, quote: "NC State's PULSTAR reactor.", found_by: "human")
    get admin_inbox_path
    assert_select "#inbox-record-organization-#{seeded.id}", /Seeded Pending Co/
    assert_select "#inbox-record-facility-#{plant.id}", /PULSTAR Reactor/
    assert_select "#inbox-record-organization-#{no_role.id}", 0, "a company without a sourced category stays Data Quality's"
    assert_select "nav a[href=?]", admin_inbox_path, text: /Today\s*#{OwnerInbox.new.size}/

    post admin_inbox_decide_record_path("Organization", seeded.id, "yes")
    assert seeded.reload.verified?, flash[:alert].to_s
    post admin_inbox_decide_record_path("Facility", plant.id, "no")
    assert_equal "rejected", plant.reload.verification_status
  end
end
