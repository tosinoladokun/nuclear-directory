require "test_helper"

# /companies shows the first PAGE rows and a "Show more" that keeps the
# filters, so the page stays light as the directory grows; the count is the full one.
class DirectoryPageSizeTest < ActionDispatch::IntegrationTest
  PAGE = DirectoryController::PAGE

  setup do
    Organization.insert_all((PAGE + 5).times.map { |i| { name: "Paged Fission #{i}", slug: "paged-fission-#{i}", verification_status: "verified",
      verified_by: "human:tosin", created_at: Time.current, updated_at: Time.current } })
  end

  def rows = css_select("main ul.nd-list > li").size

  test "the first page, the full count, and Show more with the filters kept" do
    get companies_path(q: "Paged Fission")
    assert_select "h1 .nd-listhead__count", /#{PAGE + 5} results/
    assert_equal PAGE, rows
    assert_select "a.nd-btn[rel=nofollow][href=?]", companies_path(q: "Paged Fission", shown: 2), "Show more"

    get companies_path(q: "Paged Fission", shown: 2)
    assert_equal PAGE + 5, rows
    assert_select "a", text: "Show more", count: 0
  end
end
