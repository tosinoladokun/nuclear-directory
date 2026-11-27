require "csv"

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
  DOCUMENT_TITLE = /\b(?:summary report|audit plan|assignment of project number|presentation materials|transmittal)\b|\bML\d{5}[A-Z]?\d{3,5}\b|\b(?:docket|project)\s*(?:no\.?|number)?\s*\d{2,}/i
  COUNTRY_SOURCES = %w[lead_finder wire_press].freeze
  # The plant links that mean a utility owns or runs one; never vendor_for or offtakes_from (Copilot).
  PLANT_LINKS = %w[owns operates].freeze

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
      # Only award text that was read: a recipient row or an unreadable row says nothing either way (DQ, #1003).
      texts = claims.flat_map { |claim| self.class.award_texts(claim) }.reject(&:blank?)
      return "its award records name no nuclear work" if texts.any? && texts.none? { |text| nuclear?(text) }
    end
    if org.eia_utility_id.present? && !kinds.include?("eia_owners") && FacilityRelationship.where(organization_id: org.id, relationship_type: PLANT_LINKS).none?
      return "a utility that owns or runs no nuclear plant"
    end
    foreign = claims.select { |claim| claim.source&.source_kind.in?(COUNTRY_SOURCES) }
      .map { |claim| claim.payload.to_h }.find { |payload| payload["country_code"].present? && payload["country_code"] != "US" }
    "its record says it's in #{foreign['country_code']}, with no US address" if foreign && org.hq_state.blank? && claims.none? { |claim| claim.payload.to_h["hq_state"].present? }
  end

  # What an award record says about the work, one text per award: for a
  # USAspending recipient's source, every award's description column (its
  # search column is the crawler's own label, and its claim quotes only the
  # largest award; Copilot); a recipient row has none; an ARPA-E line is all
  # award text (DQ, #1003).
  def self.award_texts(claim)
    case claim.source&.source_kind
    when "usaspending_doe_awards"
      rows = (CSV.parse(claim.source.content_text.to_s, headers: true) rescue nil)
      descriptions = rows ? rows.filter_map { |row| row["description"].to_s.squish.presence if row["recipient_name"].present? } : []
      descriptions.presence || [ description_of(claim.quote) ].compact
    when "usaspending_recipients" then []
    else [ claim.quote.to_s ]
    end
  end

  # The description column of one award row, as the plugin writes it, or nil.
  def self.description_of(row)
    columns = DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS
    fields = (CSV.parse_line(row.to_s) rescue nil)
    fields[columns.index("description")].to_s.squish.presence if fields && fields.size == columns.size
  end

  # Nuclear words other than LENR's ("low-energy nuclear reactions" names nuclear but isn't; DQ, 28 Nov).
  def self.nuclear?(text) = text.gsub(LENR, " ").match?(DataQuality::Plugins::LeadFinder::NUCLEAR)

  private
    def nuclear?(text) = self.class.nuclear?(text)

    def open?(claim) = claim.status.in?(DataQuality::Recommendations::OPEN)

    def never?(org) = DqPass.never_reject?(org)
end
