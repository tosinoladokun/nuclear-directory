require "test_helper"

# #591: one form to correct, claim or update a listing, or suggest a new
# company or plant. Each change becomes a normal claim; nothing publishes.
class ListingSubmissionTest < ActionDispatch::IntegrationTest
  setup do
    @company = Organization.create!(name: "Claimed Fission", domain: "claimedfission.com", website: "https://claimedfission.com",
      verification_status: "verified", verified_by: "human:tosin")
  end

  def submit(**fields) = post(corrections_path, params: { subject: "Claimed Fission", page_path: "/companies/x", **fields })

  test "a listing update becomes one claim per change, from a visitor, with its source; a company-domain email is noted" do
    submit(kind: "listing", record_type: "Organization", record_id: @company.id, source_url: "https://claimedfission.com/about",
      claimant_name: "Ana", claimant_role: "Comms", claimant_email: "ana@claimedfission.com",
      proposed_changes: [ { field: "hq_city", value: "Austin", quote: "Claimed Fission is based in Austin." }, { field: "founded_year", value: "2019" } ])
    report = CorrectionReport.last
    assert_equal "listing", report.kind
    assert report.email_domain_match
    claims = Candidate.where(id: report.candidate_ids).order(:id)
    assert_equal 2, claims.size
    assert_equal [ "organization", "visitor", "new" ], claims.first.values_at(:kind, :origin, :status)
    assert_equal({ "name" => "Claimed Fission", "hq_city" => "Austin" }, claims.first.payload)
    assert_equal "Claimed Fission is based in Austin.", claims.first.quote
    assert_equal "https://claimedfission.com/about", claims.first.source.url
    assert_match "company's domain", claims.first.notes
    assert_equal "verified", @company.reload.verification_status
    assert_nil @company.hq_city, "nothing changes until Tosin's Yes"
  end

  test "a new company suggestion becomes a claim; a name or source is required; fields outside the list are refused" do
    submit(kind: "new_record", record_type: "Organization", source_url: "https://example.com/new", proposed_changes: [ { field: "name", value: "Brand New Reactors" } ])
    claim = Candidate.find(CorrectionReport.last.candidate_ids.sole)
    assert_equal({ "name" => "Brand New Reactors" }, claim.payload)

    assert_no_difference -> { CorrectionReport.count } do
      submit(kind: "listing", record_type: "Organization", record_id: @company.id, proposed_changes: [ { field: "hq_city", value: "Austin" } ])
    end
    assert_no_difference -> { CorrectionReport.count } do
      submit(kind: "listing", record_type: "Organization", record_id: @company.id, source_url: "https://x.com", proposed_changes: [ { field: "name", value: "Other" } ])
    end
  end

  test "a plain correction still works as before, and a visitor's claim waits for Data Quality before Tosin" do
    submit(message: "The city is wrong.")
    assert_equal [ "correction", [] ], CorrectionReport.last.values_at(:kind, :candidate_ids)

    page = Source.create!(url: "https://example.com/v", source_kind: "web_page", crawl_status: "ok", content_text: "q")
    claim = Candidate.create!(source: page, kind: "organization", status: "needs_review", origin: "visitor", quote: "q",
      payload: { "name" => "Claimed Fission", "hq_city" => "Austin" }, subject_type: "Organization", subject_id: @company.id)
    assert_equal "dq", DataQuality::Review.inbox_kind(claim)
    DataQuality::Recommendations.record("#{claim.id} approve: their own about page says Austin", by: "human:dq")
    assert_equal "change", DataQuality::Review.inbox_kind(claim.reload)
  end
end
