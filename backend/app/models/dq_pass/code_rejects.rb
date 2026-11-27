# Data Quality's pass, step 1 (#998): recommends reject, in code and with no
# model, for a pending company whose own records show it's out of scope.
# Data Quality's rules (28 Nov). It only recommends: Tosin's Accept decides.
#
# - An award recipient (ARPA-E, USAspending) whose award texts name no
#   nuclear work. LENR ("low-energy nuclear reactions") isn't nuclear work.
# - A utility (it has an EIA utility ID) that owns or runs no nuclear plant
#   in the directory, when it didn't come from EIA's owners file.
# - A name that is a document's title, not a company's.
# - A record that gives a country outside the US and no US state.
#
# Never: a university, a national lab or a government body (the model reads
# those), a company a person suggested, or an investor.
class DqPass::CodeRejects
  AWARDS = %w[arpa_e_projects usaspending_doe_awards usaspending_recipients].freeze
  LENR = /\b(?:low[- ]energy nuclear reactions?|LENR)\b/i
  DOCUMENT_TITLE = /\b(?:summary report|audit plan|assignment of project number|presentation materials|transmittal)\b|\bML\d{8,}\b|\b(?:docket|project)\s*(?:no\.?|number)?\s*\d{2,}/i
  NEVER = /\b(?:universit(?:y|ies)|college|institute of technology|national lab(?:oratory)?|laboratory|department of|u\.s\. |agency|administration|authority|commission|capital|ventures|partners|fund)\b/i
  COUNTRY_SOURCES = %w[lead_finder wire_press].freeze

  def initialize(apply: ->(rows) { DataQuality::Matching.apply(rows) })
    @apply = apply
  end

  def call(_run)
    rows = due.flat_map do |org, claims|
      why = reason_for(org, claims) or next []
      claims.select { |claim| open?(claim) && claim.dq_recommendation.nil? }.map do |claim|
        { "action" => "recommend", "id" => claim.id, "verdict" => "reject", "reason" => "Server pass (code): #{why}",
          "request_key" => "dq-pass:reject:#{claim.id}" }
      end
    end
    results = rows.any? ? @apply.call(rows) : []
    { "code_rejects" => Array(results).count(&:ok) }
  end

  # Each pending company with an open company claim, and all its company claims (open or not).
  def due
    open = Candidate.where(kind: "organization", subject_type: "Organization", status: DataQuality::Recommendations::OPEN)
    orgs = Organization.where(verification_status: "pending", id: open.select(:subject_id)).order(:id).to_a
    claims = Candidate.where(kind: "organization", subject_type: "Organization", subject_id: orgs.map(&:id)).includes(:source).order(:id).to_a.group_by(&:subject_id)
    orgs.map { |org| [ org, claims.fetch(org.id, []) ] }
  end

  # Why this company is out of scope, or nil. Each rule reads all its claims, open or not.
  def reason_for(org, claims)
    return if never?(org)

    kinds = claims.map { |claim| claim.source&.source_kind }.compact.uniq
    return "the name is a document's title, not a company's" if org.name.to_s.match?(DOCUMENT_TITLE)
    if kinds.any? && (kinds - AWARDS).empty?
      texts = claims.map { |claim| claim.quote.to_s }
      return "its award records name no nuclear work" if texts.none? { |text| nuclear?(text) }
    end
    if org.eia_utility_id.present? && !kinds.include?("eia_owners") && FacilityRelationship.where(organization_id: org.id).none?
      return "a utility that owns or runs no nuclear plant"
    end
    foreign = claims.select { |claim| claim.source&.source_kind.in?(COUNTRY_SOURCES) }
      .map { |claim| claim.payload.to_h }.find { |payload| payload["country_code"].present? && payload["country_code"] != "US" }
    "its record says it's in #{foreign['country_code']}, with no US address" if foreign && org.hq_state.blank? && claims.none? { |claim| claim.payload.to_h["hq_state"].present? }
  end

  # Nuclear words other than LENR's ("low-energy nuclear reactions" names nuclear but isn't; DQ, 28 Nov).
  def self.nuclear?(text) = text.gsub(LENR, " ").match?(DataQuality::Plugins::LeadFinder::NUCLEAR)

  private
    def nuclear?(text) = self.class.nuclear?(text)

    def open?(claim) = claim.status.in?(DataQuality::Recommendations::OPEN)

    def never?(org)
      org.name.to_s.match?(NEVER) || person_suggested?(org) ||
        OrganizationRole.where(organization_id: org.id, role: Role.where(key: %w[venture_capital university national_lab government_agency])).exists?
    end

    def person_suggested?(org)
      Lead.where(kind: "company", normalized_name: Lead.normalize(org.name)).any? do |lead|
        lead.sources.any? { |source| source["key"].to_s.match?(DataQuality::Plugins::LeadFinder::PERSON_KEYS) }
      end
    end
end
