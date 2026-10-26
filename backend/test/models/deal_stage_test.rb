require "test_helper"

# #487: a deal whose terms are all a framework or another non-binding form
# is shown with its stage and never counted.
class DealStageTest < ActionDispatch::IntegrationTest
  BY = "human:tosin"

  setup do
    page = Source.create!(url: "https://example.com/stage", source_kind: "web_page", crawl_status: "ok", content_sha256: "s")
    @cite = ->(fact) { Evidence.create!(subject: fact, source: page, quote: "q", found_by: "human"); fact }
    @buyer = @cite.(Organization.create!(name: "Switch Stage Co", verification_status: "verified", verified_by: BY))
    @seller = @cite.(Organization.create!(name: "Oklo Stage Co", verification_status: "verified", verified_by: BY))
    @other = @cite.(Organization.create!(name: "Signed Seller Co", verification_status: "verified", verified_by: BY))
    @framework = @cite.(Relationship.create!(from_organization: @buyer, to_organization: @seller, relationship_type: "offtake_with",
      verification_status: "verified", verified_by: BY))
    DealTerm.create!(link: @framework, term_type: "offtake", agreement: "framework", capacity_mw: 12_000, verification_status: "verified", verified_by: BY)
    @signed = @cite.(Relationship.create!(from_organization: @buyer, to_organization: @other, relationship_type: "offtake_with",
      verification_status: "verified", verified_by: BY))
    DealTerm.create!(link: @signed, term_type: "offtake", agreement: "ppa", status: "signed", capacity_mw: 500, verification_status: "verified", verified_by: BY)
  end

  test "stage: framework, non-binding, or none for a signed deal or one with no terms" do
    assert_equal "framework", @framework.reload.stage
    assert_nil @signed.reload.stage
    @framework.deal_terms.update_all(agreement: "mou")
    assert_equal "non_binding", @framework.reload.stage
    assert_equal [ @framework.id ], Relationship.staged.pluck(:id)
  end

  test "the company page tags it and leaves it out of the count; the description says framework" do
    get company_path(slug: @buyer.slug)
    assert_select "#deals-heading small", "1"
    assert_select "span.nd-tag", "Framework"
    assert_select "meta[name=description][content*=?]", "Framework offtake with Oklo Stage Co"
    assert_select "meta[name=description][content*=?]", "Offtakes from Signed Seller Co"
  end

  test "a framework alone doesn't make a power buyer" do
    DealTerm.where(link: @signed).delete_all
    @signed.destroy!
    assert_not_includes Bucket.organization_ids(Category.find("power-buyers")).pluck(:id), @buyer.id
  end
end
