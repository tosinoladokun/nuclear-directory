# PM, 21 Oct 2026: ENTRA1's company description, Project developer role and
# SMR tag are re-sourced to ENTRA1's own site and NuScale's own page (the
# seed attaches those). The 2023 SEC filing was about Standard Power and
# doesn't support them, so its quotes on ENTRA1 come off. FactWriter's own
# rule keeps each fact sourced: a quote comes off only while another stays.
# Idempotent: a quote already gone is skipped.
class Entra1DropSecEvidence < DeployData::Migration
  BY = "human:tosin"
  SOURCE_URL = "https://www.sec.gov/Archives/edgar/data/1822966/000182296623000242/a2023-10x06xstandardpowe.htm"
  SLUG = "entra1-energy"

  def up
    company = Organization.find_by(slug: SLUG) or return say("No #{SLUG} here; nothing to do")
    source = Source.find_by(url: SOURCE_URL) or return say("The 2023 SEC filing isn't stored here; nothing to do")

    facts = [ [ "Organization", company.id ],
      *company.organization_roles.pluck(:id).map { |id| [ "OrganizationRole", id ] },
      *company.organization_technologies.pluck(:id).map { |id| [ "OrganizationTechnology", id ] } ]
    removed = 0
    facts.each do |type, id|
      Evidence.where(subject_type: type, subject_id: id, source_id: source.id).each do |row|
        Directory::FactWriter.remove_evidence(type:, id:, evidence_id: row.id, source_id: source.id, quote: row.quote, by: BY,
          reason: "The 2023 SEC filing is about Standard Power, not ENTRA1; re-sourced to ENTRA1's own site (21 Oct 2026); #{reason}")
        removed += 1
      end
    end
    say "Took #{removed} quote(s) from the 2023 SEC filing off ENTRA1 (#{company.name})"
  end
end
