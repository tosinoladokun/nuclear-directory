# PM, 18 Nov 2026: Tosin's first "Add a lead" made pending company 312 named "cameco" (a site search's spelling, kept
# by the lead; fixed in this PR). Its name becomes "Cameco" and its country Canada (HQ Saskatoon, from Cameco's own
# pages, Data Quality). It stays pending for his Create. Merging this PR is Tosin's approval.
#
# Pinned: only while company 312 is still pending and named "cameco"; already fixed is skipped; anything else stops.
class CamecoName < DeployData::Migration
  BY = "human:tosin"
  ID = 312

  def up
    company = Organization.find_by(id: ID) or raise "company #{ID} is gone"
    return say("Company #{ID} is already Cameco, CA") if company.name == "Cameco" && company.country_code == "CA"
    unless company.name == "cameco" && company.verification_status == "pending"
      raise "company #{ID} is no longer the pending 'cameco': #{company.name.inspect}, #{company.verification_status}"
    end

    result = Directory::FactWriter.write("organization", { id: ID, name: "Cameco", country_code: "CA" },
      verification: { status: "pending", by: BY, reason: "the lead's search spelling; Cameco's own pages (Saskatoon, Canada); #{reason}" },
      protect_human_verified: false)
    raise "company #{ID}: #{result.errors.to_sentence}" unless result.ok?

    say "Company #{ID}: Cameco, CA"
  end
end
