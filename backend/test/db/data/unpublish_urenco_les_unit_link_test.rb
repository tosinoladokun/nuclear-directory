require "test_helper"
load Rails.root.join("db/data/20261126150000_unpublish_urenco_les_unit_link.rb")

# #957: Urenco's operates link to the LES unit comes off as Tosin's decision; the site's link, the unit and the
# evidence stay, and anything else about the link is left and said.
class UnpublishUrencoLesUnitLinkTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    [ FacilityRelationship.find_by(id: [ 42, 269 ]), Facility.find_by(id: [ 207, 27 ]), Organization.find_by(id: 41) ].compact.each(&:destroy!)
    @urenco = Organization.create!(id: 41, name: "Urenco", verification_status: "verified", verified_by: BY)
    @site = Facility.create!(id: 27, name: "National Enrichment Facility", facility_type: "enrichment", state: "NM", verification_status: "verified", verified_by: BY)
    @unit = Facility.create!(id: 207, name: "Louisiana Energy Services (LES)", parent: @site, facility_type: "enrichment", nrc_docket: "07003103",
      verification_status: "verified", verified_by: BY)
    @site_link = FacilityRelationship.create!(id: 42, organization: @urenco, facility: @site, relationship_type: "operates", verification_status: "verified", verified_by: BY)
    @link = FacilityRelationship.create!(id: 269, organization: @urenco, facility: @unit, relationship_type: "operates", verification_status: "verified", verified_by: BY)
    @evidence = @link.evidence.create!(source: sources(:nrc), quote: "Louisiana Energy Services, LLC (LES), a Urenco company.", found_by: "human", confidence: 1)
  end

  def run_it = UnpublishUrencoLesUnitLink.new(reason: "deploy abc1234, PR #1").tap(&:up)
  def said = run_it.output.join("\n")

  test "takes the unit's link off as Tosin's decision; the site's link, the unit, its docket and the evidence stay" do
    output = said

    assert_equal "unpublished", @link.reload.verification_status
    event = VerificationEvent.where(subject: @link).order(:id).last
    assert_equal [ BY, "unpublished" ], [ event.by, event.to_status ]
    assert_match "Same plant as its site's operates link (#957); deploy abc1234, PR #1", event.reason
    assert_includes output, "Took off link 269 (Urenco operates Louisiana Energy Services (LES))"
    assert_equal "verified", @site_link.reload.verification_status
    assert_equal [ "verified", "07003103" ], @unit.reload.attributes.values_at("verification_status", "nrc_docket")
    assert Evidence.exists?(@evidence.id)
    assert FacilityRelationship.exists?(269)
  end

  test "a rerun changes nothing and says so" do
    run_it
    assert_no_difference "VerificationEvent.count" do
      assert_includes said, "Link 269 (Urenco operates LES) is unpublished now; left as it is"
    end
  end

  test "a link no longer verified, or no longer Urenco operates LES, is left and said, never a stopped deploy" do
    @link.update_columns(verification_status: "pending")
    assert_includes said, "is pending now; left as it is"
    assert_equal "pending", @link.reload.verification_status

    @link.update_columns(verification_status: "verified", relationship_type: "owns")
    assert_includes said, "not Urenco operates LES; left as it is"
    assert_equal "verified", @link.reload.verification_status
  end

  test "a missing link is said, not raised" do
    @link.destroy!
    assert_includes said, "Link 269 is gone"
  end
end
