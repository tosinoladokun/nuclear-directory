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

  test "a filtered search that finds nothing isn't a gap; a long query with an email past 100 characters isn't kept" do
    Organization.create!(name: "Statey Fission", hq_state: "CA", verification_status: "verified", verified_by: "human:tosin")
    state = DirectoryListing.new.state_options.first
    assert state, "a state to filter by"
    get companies_path(q: "Zzyzx Fission", state:), headers: BROWSER
    get companies_path(q: "Zzyzx Fission", category: "fuel"), headers: BROWSER
    get companies_path(q: "#{'nuclear ' * 13}me@example.com"), headers: BROWSER
    assert_equal 0, SearchGap.count
  end

  test "the gap is the search that ran: a long run of spaces cut at 100 characters keys the same words the listing searched" do
    get companies_path(q: "Ocean#{' ' * 100}Atomics"), headers: BROWSER
    assert_equal [ "ocean" ], SearchGap.pluck(:query)
  end
end
