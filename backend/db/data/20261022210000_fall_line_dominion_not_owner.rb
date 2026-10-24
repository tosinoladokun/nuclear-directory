# PM, 22 Oct 2026, from the Founder's check of CFS's release: Dominion Energy
# Virginia owns the LAND at the Fall Line site and CFS has leasing rights;
# CFS will own and operate the plant. "owns" is an ownership share of the
# plant (DATA.md), so the link "Dominion owns Fall Line" comes off the site.
# The seed no longer carries it; CFS's own link stays, now saying leasing
# rights, not a signed lease. Merging this PR is Tosin's approval.
class FallLineDominionNotOwner < DeployData::Migration
  BY = "human:tosin"
  LINK_ID = 8

  def up
    link = FacilityRelationship.find_by(id: LINK_ID) or raise "link #{LINK_ID} is gone"
    ends = [ link.organization&.name, link.facility&.name ]
    unless link.relationship_type == "owns" && ends == [ "Dominion Energy", "Fall Line Fusion Power Station" ]
      raise "link #{LINK_ID} is no longer Dominion Energy owns Fall Line Fusion Power Station: #{link.relationship_type} #{ends.inspect}"
    end
    return say("Link #{LINK_ID} (Dominion owns Fall Line) is already unpublished") if link.verification_status == "unpublished"

    result = DataQuality::Review.unpublish(type: "FacilityRelationship", id: LINK_ID, by: BY,
      reason: "Dominion owns the site (land), not the plant; CFS will own and operate it (CFS release, 17 Dec 2024); #{reason}")
    raise "unpublishing link #{LINK_ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off link #{LINK_ID} (Dominion owns Fall Line Fusion Power Station)"
  end
end
