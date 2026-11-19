# PM, 18 Nov 2026: Tosin's first "Add a lead" made pending company 312 named "cameco" (a site search's spelling, kept
# by the lead; fixed in this PR). Its name becomes "Cameco" and its country Canada (HQ Saskatoon, from Cameco's own
# pages, Data Quality). It stays pending for his Create. Merging this PR is Tosin's approval.
#
# Pinned: only while company 312 is still named "cameco", pending or verified (its status kept); already fixed or
# anything else is skipped and named, so the data deploy never stops here.
class CamecoName < DeployData::Migration
  BY = "human:tosin"
  ID = 312

  def up
    company = Organization.find_by(id: ID) or return say("Company #{ID} is gone; nothing to do")
    return say("Company #{ID} is already Cameco, CA") if company.name == "Cameco" && company.country_code == "CA"
    # Pending, or already created by Tosin before this deployed (Infra, 19 Nov: the pin stopped every later step):
    # the same intent either way, and its status is kept.
    # Anything else was decided by a person since: left as it is and named, never a stopped deploy (Infra, PM).
    unless company.name.casecmp?("cameco") && %w[pending verified].include?(company.verification_status)
      return say("Company #{ID} left as it is: #{company.name.inspect}, #{company.verification_status}")
    end

    result = Directory::FactWriter.write("organization", { id: ID, name: "Cameco", country_code: "CA" },
      verification: { status: company.verification_status, by: BY, reason: "the lead's search spelling; Cameco's own pages (Saskatoon, Canada); #{reason}" },
      protect_human_verified: false)
    raise "company #{ID}: #{result.errors.to_sentence}" unless result.ok?

    say "Company #{ID}: Cameco, CA"
  end
end
