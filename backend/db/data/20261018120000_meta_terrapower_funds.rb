# Tosin, 17 Oct 2026: Meta–TerraPower is funding, not a power deal (DATA.md).
# The seed writes the new Meta → TerraPower "funds" link; this takes the old
# "offtake_with" link (34) off the public site, recorded as Tosin's decision.
class MetaTerrapowerFunds < DeployData::Migration
  BY = "human:tosin"
  LINK_ID = 34

  def up
    link = Relationship.find_by(id: LINK_ID) or raise "link #{LINK_ID} is gone"
    ends = [ link.from_organization&.name, link.to_organization&.name ]
    unless link.relationship_type == "offtake_with" && ends == [ "Meta", "TerraPower" ]
      raise "link #{LINK_ID} is no longer Meta offtake_with TerraPower: #{link.relationship_type} #{ends.inspect}"
    end
    return say("Link #{LINK_ID} (Meta offtake_with TerraPower) is already unpublished") if link.verification_status == "unpublished"

    result = DataQuality::Review.unpublish(type: "Relationship", id: LINK_ID, by: BY,
      reason: "Re-typed as Meta funds TerraPower (Tosin, 17 Oct 2026); #{reason}")
    raise "unpublishing link #{LINK_ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off link #{LINK_ID} (Meta offtake_with TerraPower); the seed's funds link replaces it"
  end
end
