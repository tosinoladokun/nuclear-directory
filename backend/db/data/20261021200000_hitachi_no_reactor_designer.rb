# PM, 21 Oct 2026, from Tosin's rule (DATA.md, #322): a parent never inherits
# its subsidiary's buckets. Hitachi's own pages don't say it designs reactors
# (its Reactor designer role rested on a quote about GE Vernova Hitachi
# Nuclear Energy), so the role comes off. GE Vernova Hitachi keeps it; Hitachi
# stays linked to it as a parent. The seed no longer carries the role.
class HitachiNoReactorDesigner < DeployData::Migration
  BY = "human:tosin"
  ROLE_ID = 72

  def up
    role = OrganizationRole.find_by(id: ROLE_ID) or raise "role #{ROLE_ID} is gone"
    unless role.organization&.name == "Hitachi" && role.role&.key == "reactor_vendor"
      raise "role #{ROLE_ID} is no longer Hitachi reactor_vendor: #{role.organization&.name} #{role.role&.key}"
    end
    return say("Role #{ROLE_ID} (Hitachi reactor_vendor) is already unpublished") if role.verification_status == "unpublished"

    result = DataQuality::Review.unpublish(type: "OrganizationRole", id: ROLE_ID, by: BY,
      reason: "A parent never inherits its subsidiary's buckets; Hitachi's own pages don't say it designs reactors (21 Oct 2026); #{reason}")
    raise "unpublishing role #{ROLE_ID} failed: #{Array(result.errors).join('; ')}" unless result.ok?

    say "Took off role #{ROLE_ID} (Hitachi reactor_vendor)"
  end
end
