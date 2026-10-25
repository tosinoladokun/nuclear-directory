require "test_helper"

# #559: the short description is edited on the company's Edit page, with a
# counter, a preview of the row, and a refusal over 40 characters.
class Admin::ShortDescriptionEditTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    @company = Organization.create!(name: "Edit Short Co", verification_status: "verified", verified_by: "human:tosin")
    page = Source.create!(url: "https://example.com/edit-short", source_kind: "web_page", crawl_status: "ok", content_sha256: "s")
    Evidence.create!(subject: @company, source: page, quote: "Edit Short Co enriches uranium.", found_by: "human")
  end

  test "Edit shows the field with its counter and preview, saves it, and refuses 41 characters" do
    get admin_record_edit_path(type: "Organization", id: @company.id)
    assert_select "input#values_short_description[maxlength='40']"
    assert_select "#short-description-count", "40 left"
    assert_select "[data-short-description-target=preview]", "Role · specialty until it's written"

    patch admin_record_path(type: "Organization", id: @company.id), params: { values: { short_description: "Uranium enrichment, including HALEU" } }
    assert_equal "Uranium enrichment, including HALEU", @company.reload.short_description

    patch admin_record_path(type: "Organization", id: @company.id), params: { values: { short_description: "x" * 41 } }
    assert_response :unprocessable_content
    assert_equal "Uranium enrichment, including HALEU", @company.reload.short_description
  end
end
