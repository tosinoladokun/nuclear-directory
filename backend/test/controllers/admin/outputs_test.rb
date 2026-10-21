require "test_helper"

# Where it appears (#166): what the public sees, counted the way the
# sitemap lists it.
class Admin::OutputsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    company = Organization.create!(name: "Imaginary Fission", verification_status: "verified", verified_by: "human:tosin")
    Evidence.create!(subject: company, source: sources(:press_release), quote: "Imaginary Fission", found_by: "human")
  end

  test "public pages counted as the sitemap lists them, link previews, the snapshot's last change, and the dataset to come" do
    get sitemap_path
    in_sitemap = Nokogiri::XML(response.body).remove_namespaces!.xpath("//url/loc").size

    get admin_outputs_path

    assert_select "h1", /Where it appears\s+#{in_sitemap}/
    assert_select "#output-pages", /Public pages\s+#{in_sitemap}/
    pages = PublicPages.new
    assert_operator Category.all.size, :>, pages.categories.size, "some categories are empty here"
    assert_select "#output-previews", /Link previews\s+#{pages.companies.count + pages.plants.count + Category.all.size + 1}/,
      "an empty category's page still has its own card"
    assert_select "#output-snapshot", /Snapshot API\s+Updated \d+ \w{3}, /
    assert_select "#output-snapshot a[href=?]", api_snapshot_path
    assert_select "#output-dataset", /Open dataset\s+Later/
  end

  test "the nav's Where it appears is a link now, with its count" do
    get admin_outputs_path
    assert_select ".nd-shell__nav a[href=?][aria-current]", admin_outputs_path, /Where it appears\s+\d+/
    assert_select ".nd-shell__soon", text: /Where it appears/, count: 0
  end
end
