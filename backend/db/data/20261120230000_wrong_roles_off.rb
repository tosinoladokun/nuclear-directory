# Data Quality, 20 Nov 2026 (audit of Tosin's inbox clear: 46 claims the verifier couldn't confirm or contradicted):
# seven role rows on published companies are not what the companies' own pages say, and come off. A role such as
# "Molten salt", "Water", "Fuel" or "Enrichment" is a supply-chain material or supplier, and none of these companies
# says it is one:
# - Natura Resources: molten salt (it develops molten salt reactors, it does not supply the salt), water (its reactors
#   cool with salt instead of water).
# - Flibe: molten salt (it designs molten salt reactors).
# - Marathon Fusion: fuel (it develops fusion fuel-cycle systems), enrichment (a lithium plasma centrifuge, not
#   uranium enrichment), research organization (nothing on the page says it).
# - Aalo Atomics: fuel (it assembles its own fuel, it does not supply fuel; its fabrication role stays).
#
# Merging this PR is Tosin's approval. Pinned on each role row's id, its company and its role as Data Quality read them
# in production on 20 Nov: a row that is not as read, was decided again since, or is already off is skipped and said,
# never a stopped deploy; a real failure raises, so the deploy records it, alerts and retries.
class WrongRolesOff < DeployData::Migration
  BY = "human:tosin"
  # role row id => [company, role key]
  ROWS = {
    495 => [ "Aalo Atomics", "fuel" ],
    497 => [ "Flibe", "molten_salt" ],
    506 => [ "Marathon Fusion", "fuel" ],
    507 => [ "Marathon Fusion", "enrichment" ],
    508 => [ "Natura Resources LLC", "molten_salt" ],
    509 => [ "Natura Resources LLC", "water" ],
    512 => [ "Marathon Fusion", "research_organization" ]
  }.freeze
  REASON = "Not stated by the company: a supply-chain role it does not have".freeze
  # Every row was last decided before this read (the inbox clear ran until 20:18 UTC).
  READ_AT = Time.utc(2026, 11, 20, 21)

  def up
    ROWS.each do |id, (company, key)|
      row = OrganizationRole.includes(:organization, :role).find_by(id:)
      next say("Role row #{id} (#{company}, #{key}) is gone; nothing to do") unless row
      next say("Role row #{id} (#{company}, #{key}) is already #{row.verification_status}") if row.verification_status == "unpublished"
      next say("Role row #{id} is #{row.organization&.name.inspect} / #{row.role&.key.inspect}, not #{company} / #{key}; left as it is") unless [ row.organization&.name, row.role&.key ] == [ company, key ]
      next say("Role row #{id} (#{company}, #{key}) is #{row.verification_status}, not verified; left as it is") unless row.verification_status == "verified"
      next say("Role row #{id} (#{company}, #{key}) was decided again; left as it is") if decided_since_read?(row)

      result = DataQuality::Review.unpublish(type: "OrganizationRole", id:, by: BY, reason: "#{REASON}; #{reason}")
      raise "taking off role row #{id} failed: #{Array(result.errors).join('; ')}" unless result.ok?

      say "Took off role row #{id} (#{company}: #{key})"
    end
  end

  private
    # A later verified_at, or any later verification event (a same-reviewer edit keeps verified_at but records an event).
    def decided_since_read?(record)
      return true if record.verified_at.nil? || record.verified_at >= READ_AT

      VerificationEvent.where(subject: record).where(created_at: READ_AT..).exists?
    end
end
