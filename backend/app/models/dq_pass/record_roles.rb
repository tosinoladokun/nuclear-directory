# Data Quality's pass, step 2 (#998): proposes a role, in code and with no
# model, where a record states it. Data Quality's rules (28 Nov) allow only
# these here; every other role is left for research.
#
# - national_lab: a DOE national laboratory by DOE's own list of the 17
#   (energy.gov/national-laboratories), quoted by its name on that page.
# - university: a university (.edu website) on a DOE or ARPA-E award whose
#   text names nuclear or fusion work (not LENR), quoted from that award.
#
# Not yet (a follow-up): EIA's utilities (needs EIA's entity type, which
# isn't read today), NRC operating and fuel cycle licensees (no pending
# company comes from those). Never from a record: reactor designer or
# project developer, a company's award, or an NRC pre-application docket.
class DqPass::RecordRoles
  LABS_URL = "https://www.energy.gov/national-laboratories".freeze
  # As DOE's page writes them (read 28 Nov 2026).
  LABS = [
    "Ames National Laboratory", "Argonne National Laboratory", "Brookhaven National Laboratory",
    "Fermi National Accelerator Laboratory", "Lawrence Berkeley National Laboratory", "Oak Ridge National Laboratory",
    "Pacific Northwest National Laboratory", "Princeton Plasma Physics Laboratory", "SLAC National Accelerator Laboratory",
    "Thomas Jefferson National Accelerator Facility", "Lawrence Livermore National Laboratory", "Los Alamos National Laboratory",
    "Sandia National Laboratories", "Idaho National Laboratory", "National Energy Technology Laboratory",
    "National Laboratory of the Rockies", "Savannah River National Laboratory"
  ].freeze
  AWARDS = %w[arpa_e_projects usaspending_doe_awards doe_programs].freeze
  UNIVERSITY = /\b(?:universit(?:y|ies)|college|institute of technology)\b/i

  def initialize(apply: ->(rows) { DataQuality::Matching.apply(rows) })
    @apply = apply
  end

  def call(_run)
    rows = due.filter_map { |org| lab_row(org) || university_row(org) }
    results = rows.any? ? @apply.call(rows) : []
    { "record_roles" => Array(results).count(&:ok) }
  end

  # Pending companies with no role yet, sourced or proposed.
  def due
    roled = OrganizationRole.select(:organization_id)
    proposed = Candidate.where(kind: "organization_role", status: DataQuality::Recommendations::OPEN)
      .pluck(Arel.sql("payload->'organization'->>'name'")).compact.map(&:downcase).to_set
    Organization.where(verification_status: "pending").where.not(id: roled).order(:id).to_a
      .reject { |org| proposed.include?(org.name.downcase) }
  end

  def lab_row(org)
    names = [ org.name, *OrganizationAlias.where(organization_id: org.id).pluck(:alias) ].map { |name| name.to_s.squish.downcase }
    lab = LABS.find { |name| names.include?(name.downcase) } or return
    row(org, "national_lab", LABS_URL, lab, "on DOE's list of the 17 national laboratories")
  end

  def university_row(org)
    return unless org.name.to_s.match?(UNIVERSITY) && edu?(org.website)

    award = Candidate.where(kind: "organization", subject_type: "Organization", subject_id: org.id).includes(:source).order(:id)
      .find { |claim| claim.source&.source_kind.in?(AWARDS) && DqPass::CodeRejects.nuclear?(claim.quote.to_s) } or return
    row(org, "university", award.source.url, award.quote, "a university on a nuclear or fusion award")
  end

  private
    def edu?(website) = (URI.parse(website.to_s).host.to_s.downcase.end_with?(".edu") rescue false)

    def row(org, role, url, quote, why)
      { "action" => "propose_role", "target" => org.id, "role" => role, "source_url" => url, "quote" => quote,
        "reason" => "Server pass (code): #{why}", "request_key" => "dq-pass:role:#{org.id}:#{role}" }
    end
end
