require "test_helper"

# DQ, 24 Oct: a source naming a company we have under another spelling
# ("URENCO–USA" for Urenco) reads as what approving does: the source is
# added and the name stays (DATA.md D1), never "There is a company named…".
class Admin::ClaimTextTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as users(:admin)
    @urenco = Organization.create!(name: "Urenco", verification_status: "verified", verified_by: "human:tosin")
    @urenco.aliases.create!(alias: "Urenco")
    @urenco.aliases.create!(alias: "Urenco USA")
    @page = Source.create!(url: "https://www.nrc.gov/test/les.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: "Licensee: URENCO–USA")
    @claim = Candidate.create!(source: @page, kind: "organization", payload: { "name" => "URENCO–USA" }, quote: "Licensee: URENCO–USA",
      status: "matched", subject_type: "Organization", subject_id: @urenco.id, notes: "Matched existing Urenco (by name)",
      ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
  end

  test "Checks says the source is added and the name stays; approving adds evidence, never renames or duplicates an alias" do
    get admin_checks_path
    assert_select "#claim-#{@claim.id}", /Urenco, named “URENCO–USA” in this source\. Approving adds the source; its name stays Urenco\./
    assert_select "#claim-#{@claim.id}", text: /There is a company named/, count: 0

    assert DataQuality::Review.approve([ @claim.id ], by: "human:tosin").sole.ok?
    assert_equal "Urenco", @urenco.reload.name
    assert_equal [ "Urenco", "Urenco USA" ], @urenco.aliases.pluck(:alias).sort, "the en-dash spelling is the same alias"
    assert Evidence.exists?(subject: @urenco, source: @page, quote: "Licensee: URENCO–USA")
  end
end
