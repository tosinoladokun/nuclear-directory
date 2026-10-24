require "test_helper"

# PM, 24 Oct: a claim on a record a person decided that would only add its
# source (no value differs, any name is one the record has) isn't held for a
# one-by-one decision; anything that changes a value, or a new alias, is.
class DataQuality::EvidenceOnlyTest < ActiveSupport::TestCase
  setup do
    @urenco = Organization.create!(name: "Urenco", hq_city: "Eunice", verification_status: "verified", verified_by: "human:tosin")
    @urenco.aliases.create!(alias: "Urenco")
    @urenco.aliases.create!(alias: "Urenco USA")
    @page = Source.create!(url: "https://www.nrc.gov/test/les2.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha")
  end

  def claim(payload) = Candidate.create!(source: @page, kind: "organization", payload:, quote: "q", status: "matched",
    subject_type: "Organization", subject_id: @urenco.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")

  test "only evidence: not held; a changed value or a new alias: held" do
    assert_nil DataQuality::Review.held_reason(claim({ "name" => "URENCO–USA" }), firsts: {})
    assert_nil DataQuality::Review.held_reason(claim({ "name" => "Urenco", "hq_city" => "Eunice" }), firsts: {})
    held = "it would change a record a person decided"
    assert_equal held, DataQuality::Review.held_reason(claim({ "name" => "Urenco", "hq_city" => "Houston" }), firsts: {})
    assert_equal held, DataQuality::Review.held_reason(claim({ "name" => "Urenco Enrichment Company" }), firsts: {}), "a new alias asks"
  end

  test "Approve all takes an evidence-only claim, rechecked at the decision: a value changed meanwhile holds it" do
    same = claim({ "name" => "URENCO–USA" })
    changed = claim({ "name" => "Urenco" })
    @urenco.update_columns(hq_city: nil)
    changed.update_columns(payload: { "name" => "Urenco", "hq_city" => "Eunice" })
    results = DataQuality::Review.approve([ same.id, changed.id ], by: "human:tosin", only_recommended: true)
    assert results.find { |r| r.candidate_id == same.id }.ok?
    assert_not results.find { |r| r.candidate_id == changed.id }.ok?, "it fills a value now, so a person decides"
    assert Evidence.exists?(subject: @urenco, source: @page)
    assert_equal [ "Urenco", nil ], @urenco.reload.values_at(:name, :hq_city)
  end
end
