require "test_helper"

# Search gaps (#483): recorded from the site's search, listed for the admin
# most searched first, with Research, Covered and Ignore.
class Admin::SearchGapsTest < ActionDispatch::IntegrationTest
  BROWSER = { "User-Agent" => "Mozilla/5.0 (Macintosh) Safari/605.1.15" }.freeze

  test "a search on the site that finds nothing is recorded, without the visitor; one that finds something isn't" do
    get companies_path(q: "Zzyzx Fission"), headers: BROWSER
    get companies_path(q: "Zzyzx Fission"), headers: BROWSER
    assert_equal [ "zzyzx fission", 2 ], SearchGap.sole.values_at(:query, :searches_count)
    assert_not SearchGap.column_names.intersect?(%w[ip user_agent session_id visitor_id])

    get companies_path(q: "Zzyzx Fission"), headers: { "User-Agent" => "Googlebot/2.1" }
    assert_equal 2, SearchGap.sole.searches_count, "bots aren't counted"
  end

  test "the admin list, most searched first, and each decision" do
    sign_in_as users(:admin)
    3.times { SearchGap.record("ocean atomics", results: 0) }
    SearchGap.record("brown ferry", results: 0)
    get admin_search_gaps_path
    assert_equal [ "ocean atomics", "brown ferry" ], css_select(".nd-gaps tbody tr td:first-child a").map { |a| a.text.squish }
    assert_select ".nd-shell__nav a[href=?]", admin_search_gaps_path, /Search gaps\s+2/

    gap = SearchGap.find_by!(query: "brown ferry")
    post admin_search_gap_decide_path(id: gap.id, decision: "covered")
    assert_equal "“brown ferry”: marked covered.", flash[:notice]
    assert gap.reload.status_covered?
    assert_equal "human:tosin", gap.decided_by

    get admin_search_gaps_path
    assert_select "details summary", /Covered, ignored or found since\s+1/
  end
end
