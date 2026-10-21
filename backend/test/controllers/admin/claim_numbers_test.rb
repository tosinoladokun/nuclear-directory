require "test_helper"

# Every waiting item shows its number, and Checks jumps to one by number
# (Tosin, 21 Oct: "so that when you say do 1234, I can know it clearly").
class Admin::ClaimNumbersTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    source = Source.create!(url: "https://www.nrc.gov/numbers.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    @company = Organization.create!(name: "Numbered Fission Co")
    @claim = Candidate.create!(source:, kind: "organization", payload: { "name" => @company.name, "hq_city" => "Austin" }, quote: "Austin.",
      status: "matched", subject_type: "Organization", subject_id: @company.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    @new_company = Candidate.create!(source:, kind: "organization", payload: { "name" => "Brand New Co" }, quote: "Founded.",
      status: "needs_review", notes: "new company", ai_recommendation: "needs_review", ai_source_sha256: "sha")
  end

  test "Checks, Today's review, an item's page and Edit show its number" do
    get admin_checks_path
    assert_select "#claim-#{@claim.id} .nd-claim-no", "##{@claim.id}"

    get admin_today_review_path
    assert_select "#fact-#{@claim.id} .nd-claim-no", "##{@claim.id}"

    get admin_fact_path(type: "Organization", id: @company.id, claim: @claim.id)
    assert_select "#proposed .nd-claim-no", "##{@claim.id}"

    get edit_admin_candidate_path(@claim.id)
    assert_select "h1 .nd-claim-no", "##{@claim.id}"
  end

  test "Go to a number opens that item, with or without the #; an unknown number says so" do
    get admin_checks_path(go: "##{@claim.id}")
    assert_redirected_to admin_fact_path(type: "Organization", id: @company.id, from: "checks", claim: @claim.id)

    get admin_checks_path(go: @new_company.id.to_s)
    assert_redirected_to edit_admin_candidate_path(@new_company.id)

    get admin_checks_path(go: " # 99999999 ")
    assert_redirected_to admin_checks_path
    assert_equal "No item numbered 99999999.", flash[:alert]

    get admin_checks_path(go: "abc")
    assert_equal "Type a number, like 1234.", flash[:alert]
  end
end
