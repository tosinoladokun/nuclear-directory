require "test_helper"

# /companies shows the first PAGE rows and a "Show more" that keeps the
# filters, so the page stays light as the directory grows; the count is the full one.
class DirectoryPageSizeTest < ActionDispatch::IntegrationTest
  PAGE = DirectoryController::PAGE

  setup do
    Organization.insert_all((PAGE + 5).times.map { |i| { name: "Paged Fission #{i}", slug: "paged-fission-#{i}", verification_status: "verified",
      verified_by: "human:tosin", created_at: Time.current, updated_at: Time.current } })
  end

  def rows = css_select("main ul.nd-lines > li:not(.nd-lines__head)").size

  test "the first page, the full count, and Show more with the filters kept" do
    get companies_path(q: "Paged Fission")
    assert_select ".nd-pagehead__count", /#{PAGE + 5} results/
    assert_equal PAGE, rows
    assert_select "turbo-frame#directory-rows[target=_top]", 1, "company and plant links leave the frame; only Show more targets it"
    assert_select "turbo-frame#directory-rows a.nd-btn[href=?][data-turbo-frame=directory-rows]", companies_path(q: "Paged Fission", shown: 2), "Show more"
    assert_select "a.nd-btn[rel=nofollow]", count: 0, message: "crawlers may follow Show more"
    assert_select "meta[name=robots]", count: 1, message: "a search is noindex"

    get companies_path(q: "Paged Fission", shown: 2)
    assert_equal PAGE + 5, rows
    assert_select "a", text: "Show more", count: 0
  end

  test "a later page is noindex (the canonical is the plain list), and shows no Show more link when everything is shown" do
    get companies_path(shown: 2)
    assert_select "meta[name=robots][content=noindex]"
    assert_select "link[rel=canonical][href=?]", companies_url
  end

  test "companies and plants each get their own first page, so many companies never hide the plants" do
    Facility.insert_all((PAGE + 3).times.map { |i| { name: "Paged Station #{i}", slug: "paged-station-#{i}", facility_type: "power_reactor", status: "operating",
      verification_status: "verified", verified_by: "human:tosin", created_at: Time.current, updated_at: Time.current } })
    get companies_path(q: "Paged")

    assert_select "h2#plants-heading", "Plants and sites"
    assert_equal PAGE + PAGE, rows, "50 companies and 50 plants"
    assert_select "a", text: "Show more", count: 1
    get companies_path(q: "Paged", shown: 2)
    assert_equal PAGE + 5 + PAGE + 3, rows
  end

  test "Show more keeps an active role, so the other role's companies don't join the list" do
    designer = Role.find_or_create_by!(key: "reactor_vendor") { |role| role.name = "Reactor vendor" }
    developer = Role.find_or_create_by!(key: "project_developer") { |role| role.name = "Project developer" }
    now = Time.current
    builders = (PAGE + 3).times.map { |i| Organization.create!(name: "Role Builder #{i}", slug: "role-builder-#{i}", verification_status: "verified", verified_by: "human:tosin") }
    designers = 3.times.map { |i| Organization.create!(name: "Role Designer #{i}", slug: "role-designer-#{i}", verification_status: "verified", verified_by: "human:tosin") }
    source = Source.create!(url: "https://example.com/roles", source_kind: "web_page")
    (builders.map { |org| [ org, developer ] } + designers.map { |org| [ org, designer ] }).each do |org, role|
      link = OrganizationRole.create!(organization: org, role: role, verification_status: "verified", verified_by: "human:tosin", confidence: 1)
      link.evidence.create!(source: source, found_by: "human", confidence: 1)
    end

    get companies_path(category: "reactor-developers", role: "project_developer")
    assert_select "a.nd-btn[data-turbo-frame=directory-rows][href=?]", companies_path(category: "reactor-developers", role: "project_developer", shown: 2), "Show more"
    assert_equal PAGE, rows

    get companies_path(category: "reactor-developers", role: "project_developer", shown: 2)
    assert_equal PAGE + 3, rows, "only the project developers, none of the designers"
    assert_select "a[href='/companies/role-designer-0']", 0
  end

  test "a Show more frame request skips the category counts" do
    get companies_path(shown: 2)
    assert_select "nav.nd-idx", 1

    get companies_path(shown: 2), headers: { "Turbo-Frame" => "directory-rows" }
    assert_response :success
    assert_select "nav.nd-idx", 0
    assert_select "turbo-frame#directory-rows"
  end
end
