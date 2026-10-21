require "test_helper"

# Search gaps (#483): recorded from the site's search, the query only. The
# admin list is a later Leads page (PM, 21 Oct).
class SearchGapsTest < ActionDispatch::IntegrationTest
  BROWSER = { "User-Agent" => "Mozilla/5.0 (Macintosh) Safari/605.1.15" }.freeze

  test "a search on the site that finds nothing is recorded, without the visitor; one that finds something isn't" do
    get companies_path(q: "Zzyzx Fission"), headers: BROWSER
    get companies_path(q: "Zzyzx Fission"), headers: BROWSER
    assert_equal [ "zzyzx fission", 2 ], SearchGap.sole.values_at(:query, :searches_count)
    assert_not SearchGap.column_names.intersect?(%w[ip user_agent session_id visitor_id])

    get companies_path(q: "Zzyzx Fission"), headers: { "User-Agent" => "Googlebot/2.1" }
    assert_equal 2, SearchGap.sole.searches_count, "bots aren't counted"
  end
end
