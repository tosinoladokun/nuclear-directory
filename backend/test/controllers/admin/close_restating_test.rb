require "test_helper"

# A claim that only restates what the site shows (#240) is closed, not
# accepted or rejected (Tosin, 21 Oct): Checks says so and offers Close.
class Admin::CloseRestatingTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    page = Source.create!(url: "https://example.com/restated", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha",
      content_text: "Restated Fission Co holds a license.")
    @company = Organization.create!(name: "Restated Fission Co").tap { |company| company.verify!(by: "human:tosin") }
    Evidence.create!(subject: @company, source: page, quote: "Restated Fission Co holds a license.", found_by: "human")
    @claim = Candidate.create!(source: page, kind: "organization", payload: { "name" => @company.name }, quote: "Restated Fission Co holds a license.",
      status: "matched", subject_type: "Organization", subject_id: @company.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
  end

  test "Checks offers Close: already on the site, says what it does, and closes it with nothing live changed" do
    get admin_checks_path
    assert_select "#claim-#{@claim.id}", /It says what the site already shows\. Closing notes that in the history and changes nothing live\./
    assert_select "#claim-#{@claim.id} button", "Close: already on the site"
    assert_select "#claim-#{@claim.id} button", text: /\A(Approve|Reject)\z/, count: 0

    post close_admin_candidates_path, params: { candidate_id: @claim.id }
    assert_equal "confirmed", @claim.reload.status
    assert_equal "verified", @company.reload.verification_status
  end
end
