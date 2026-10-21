require "test_helper"

# Checks grouped by what to do (Design's spec on #373, Tosin 21 Oct): Ready
# for you, You decide, Not yours yet (folded); one next-step line per row,
# the black button matching it; oldest first; Today and Checks linked.
class Admin::ChecksGroupsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    @source = Source.create!(url: "https://www.nrc.gov/groups.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    older = CrawlRun.create!(stage: "crawl", source_kind: "web_page", status: "succeeded", started_at: 3.days.ago)
    # An earlier, decided batch, so today's isn't the source's first.
    @earlier = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Earlier Co" }, quote: "q", crawl_run: older, status: "rejected")
    run = CrawlRun.create!(stage: "crawl", source_kind: "web_page", status: "succeeded", started_at: 2.days.ago)
    @agreed = claim("Agreed Co", joy: "recommend_publish", run:)
    @only_joy = claim("Only Joy Co", joy: "recommend_publish", run:)
    @unsure = claim("Unsure Co", joy: "needs_review", run:, notes: "a branch office?")
    @split = claim("Split Co", joy: "recommend_publish", run:)
    DataQuality::Recommendations.record("#{@agreed.id} approve: listed\n#{@split.id} reject: not nuclear", by: "human:tosin")
  end

  def claim(name, joy:, run:, notes: nil)
    company = Organization.create!(name:)
    Candidate.create!(source: @source, kind: "organization", payload: { "name" => name, "hq_city" => "Austin" }, quote: "#{name} is in Austin.", crawl_run: run,
      status: (joy == "needs_review" ? "needs_review" : "matched"), notes:, subject_type: "Organization", subject_id: company.id,
      ai_recommendation: joy, ai_reason: "Listed.", ai_source_sha256: "sha")
  end

  def line(candidate) = css_select("#claim-#{candidate.id} .nd-next-step").text.squish

  test "each row in its group with its next step; the black button follows the verb" do
    get admin_checks_path

    assert_select "h3#group-ready", /Ready for you\s+1/
    assert_select "h3#group-decide", /You decide\s+\d+/
    assert_equal "Approve: Joy and Aminah agree", line(@agreed)
    assert_equal "Decide: only Joy checked", line(@only_joy)
    assert_equal "Decide: Joy isn't sure: a branch office?", line(@unsure)
    assert_equal "Decide: Joy accepts, Aminah rejects", line(@split)
    assert_select "section:has(#group-ready) #claim-#{@agreed.id}"
    assert_select "section:has(#group-decide) #claim-#{@split.id}"
    assert_select "#claim-#{@agreed.id} .nd-btn--primary", "Approve"
  end

  test "oldest first within a group, and Today and Checks link to each other" do
    get admin_checks_path
    ids = css_select("section:has(#group-decide) li.nd-wait[id^=claim-]").map { |li| li["id"].delete_prefix("claim-").to_i }
    assert_equal ids.sort, ids
    assert_select ".nd-crumbs a[href=?], a[href=?]", admin_today_path, admin_today_path, text: /Today/
  end

  test "what waits on Data Quality is folded under Not yours yet, its buttons kept, none black" do
    @earlier.destroy # this batch is now the source's first, which waits for Data Quality
    get admin_checks_path
    assert_select "details#group-not_yours:not([open]) summary", /Not yours yet\s+\d+/
    assert_select "details#group-not_yours #claim-#{@only_joy.id} .nd-next-step", /Wait: Aminah hasn't checked it yet/
    assert_select "details#group-not_yours #claim-#{@only_joy.id} button", text: "Approve"
    assert_select "details#group-not_yours #claim-#{@only_joy.id} .nd-btn--primary", 0
  end
end
