# Data Quality, 26 Nov 2026 (#957): Urenco is listed twice as operating its New Mexico enrichment plant: link 42 to the
# site (27) and link 269 to the plant's NRC-docketed unit, "Louisiana Energy Services (LES)" (207). It's one plant, so
# the unit's link comes off. Tosin approved ("yes, merge the Urenco duplicate", via PM); #958 takes it out of the seed.
#
# Unpublish only: link 42, unit 207 with its docket 07003103 and all evidence stay, and nothing is deleted.
# Pinned on the link's id, its ends and its type. Already off, or changed since (a person may have decided it):
# skipped and said. A real failure raises: the deploy records it, alerts and continues, and the step stays pending (#811).
class UnpublishUrencoLesUnitLink < DeployData::Migration
  BY = "human:tosin"
  LINK_ID = 269
  ORGANIZATION_ID = 41
  FACILITY_ID = 207
  REASON = "Same plant as its site's operates link (#957)".freeze

  def up
    link = FacilityRelationship.find_by(id: LINK_ID)
    return say("Link #{LINK_ID} is gone; nothing to do") unless link

    pin = [ link.organization_id, link.facility_id, link.relationship_type ]
    unless pin == [ ORGANIZATION_ID, FACILITY_ID, "operates" ]
      return say("Link #{LINK_ID} is now #{pin.inspect}, not Urenco operates LES; left as it is")
    end
    return say("Link #{LINK_ID} (Urenco operates LES) is #{link.verification_status} now; left as it is") unless link.verification_status == "verified"

    result = DataQuality::Review.unpublish(type: "FacilityRelationship", id: LINK_ID, by: BY, reason: "#{REASON}; #{reason}")
    raise "taking off link #{LINK_ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off link #{LINK_ID} (#{link.organization.name} operates #{link.facility.name}); the site's link and the unit stay"
  end
end
