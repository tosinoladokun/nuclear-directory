# One stage a reactor project or plant has reached with the NRC (#379):
# pre-application, application accepted, construction permit, operating
# licence, design approval, withdrawn or denied. A fact like any other:
# verified by a human, sourced through evidence, audited.
#
# One row per stage reached, not one row updated: Hermes 1 has two rows
# (application accepted, then construction permit), so the history is the
# rows and the current stage is the latest one.
#
# The row goes on the record that holds the docket: the unit (or a
# one-record plant), or the developer for a design approval, which is why
# exactly one of the two is set.
class LicensingStage < ApplicationRecord
  include Verifiable

  # The stages (#379). combined_licence: a Part 52 COL (Vogtle 3 and 4).
  # restart_review: a shut plant's request to restore its operating basis,
  # under NRC review (Duane Arnold); the approval is an operating_licence row.
  enum :stage, %w[pre_application application_accepted construction_permit combined_licence operating_licence restart_review design_approval withdrawn denied].index_by(&:itself),
    validate: true

  # What each stage is, in the words the issue uses. The site shows these.
  STAGE_LABELS = {
    "pre_application" => "Pre-application",
    "application_accepted" => "Application accepted",
    "construction_permit" => "Construction permit",
    "combined_licence" => "Combined licence",
    "operating_licence" => "Operating licence",
    "restart_review" => "Restart under NRC review",
    "design_approval" => "Design approval",
    "withdrawn" => "Withdrawn",
    "denied" => "Denied"
  }.freeze

  # NRC's own records: the only sources a licensing stage may be verified
  # from (#379). A press release or a news article is a lead, never a source
  # for a stage.
  NRC_DOMAIN = "nrc.gov".freeze
  # Where an NRC notice is published: the Federal Register, and the
  # government's own copy of it on govinfo.gov, where only Federal Register
  # packages count ("/content/pkg/FR-2025-05-16/…"), never the Congressional
  # Record or a hearing. A notice is the NRC's when it names the agency.
  NOTICE_DOMAINS = %w[federalregister.gov govinfo.gov].freeze
  GOVINFO_NOTICE = %r{/(?:content/pkg|app/details)/FR-\d{4}-\d{2}-\d{2}/}i
  # The agency, as it writes itself: "NRC" or the full name.
  AGENCY = /\bNRC\b|nuclear[\s\-_]+regulatory[\s\-_]+commission/i

  belongs_to :facility, optional: true
  belongs_to :organization, optional: true

  normalizes :nrc_docket, with: ->(docket) { LicensingStage.normalize_docket(docket) }
  normalizes :design_name, with: ->(name) { name.squish.presence }

  validates :nrc_docket, :effective_on, presence: true
  validates :design_name, presence: true, if: :design_approval?
  validate :one_owner
  validate :organization_only_for_a_design
  validate :design_name_only_for_a_design
  validate :expires_after_effective

  # What the public sees: verified, its unit or developer published, and an
  # NRC record behind it (#379). A stage with only a press release behind it
  # is never public.
  def self.published
    verified.where(id: nrc_backed.reselect("evidence.subject_id"))
      .where("facility_id IN (:facilities) OR organization_id IN (:organizations)",
        facilities: Facility.published.select(:id), organizations: Organization.published.select(:id))
  end

  # The stages with at least one piece of evidence from an NRC record.
  def self.nrc_backed
    Evidence.where(subject_type: "LicensingStage").joins(:source)
      .where(nrc_record_sql(quote_column: "evidence.quote")).select("evidence.subject_id")
  end

  # Whether a document is an NRC record (#379): an NRC page (any address on
  # nrc.gov, including ADAMS and the project pages), or a government
  # publication that names the Nuclear Regulatory Commission.
  def self.nrc_record?(domain:, url: nil, title: nil, quote: nil)
    domain = domain.to_s.downcase.delete_prefix("www.")
    return true if domain == NRC_DOMAIN || domain.end_with?(".#{NRC_DOMAIN}")
    return false unless NOTICE_DOMAINS.any? { |name| domain == name || domain.end_with?(".#{name}") }
    return false if (domain == "govinfo.gov" || domain.end_with?(".govinfo.gov")) && !url.to_s.match?(GOVINFO_NOTICE)

    [ url, title, quote ].compact.any? { |text| text.match?(AGENCY) }
  end

  # The same rule in SQL, for the scopes: a source on nrc.gov, or a
  # government publication that names the agency. quote_column: the
  # evidence's quote column, when the quote counts too.
  def self.nrc_record_sql(quote_column: nil)
    nrc = "sources.domain = 'nrc.gov' OR sources.domain LIKE '%.nrc.gov'"
    notice = "(sources.domain = 'federalregister.gov' OR sources.domain LIKE '%.federalregister.gov' " \
      "OR ((sources.domain = 'govinfo.gov' OR sources.domain LIKE '%.govinfo.gov') " \
      "AND sources.url ~* '/(content/pkg|app/details)/FR-[0-9]{4}-[0-9]{2}-[0-9]{2}/'))"
    agency = [ "sources.url ~* '\\mNRC\\M'", "sources.title ~* '\\mNRC\\M'",
      "sources.url ~* 'nuclear[\\s\\-_]+regulatory[\\s\\-_]+commission'",
      "sources.title ~* 'nuclear[\\s\\-_]+regulatory[\\s\\-_]+commission'" ]
    if quote_column
      agency << "#{quote_column} ~* '\\mNRC\\M'"
      agency << "#{quote_column} ~* 'nuclear[\\s\\-_]+regulatory[\\s\\-_]+commission'"
    end
    "(#{nrc} OR (#{notice} AND (#{agency.join(' OR ')})))"
  end

  # The docket as NRC writes it on one line ("50-7513") and as the
  # directory stores it ("05007513"): the same eight digits, so a stage and
  # the unit it belongs to carry the same docket. Anything else (a design
  # certification's own number) is kept as written.
  def self.normalize_docket(value)
    text = value.to_s.strip.presence or return nil
    match = text.match(/\A(\d{1,2})-(\d{1,5})\z/) or return text

    "0#{match[1].rjust(2, '0')}#{match[2].rjust(5, '0')}"
  end

  # The design's name as NRC writes it ("US460").
  def self.normalize_design_name(value) = value.to_s.squish.presence

  # The stage in the words the issue uses ("Construction permit").
  def stage_label = STAGE_LABELS.fetch(stage, stage.to_s.humanize)

  private
    # Exactly one of the two: the record that holds the docket.
    def one_owner
      return if facility_id.present? ^ organization_id.present?

      errors.add(:base, "needs a facility or an organization, not both and not neither")
    end

    # A design approval belongs to a design, and only to a developer: a
    # company, never a plant.
    def organization_only_for_a_design
      return if organization_id.blank? || design_approval?

      errors.add(:organization_id, "is only for a design approval")
    end

    def design_name_only_for_a_design
      return if design_name.blank? || design_approval?

      errors.add(:design_name, "is only for a design approval")
    end

    def expires_after_effective
      return unless expires_on && effective_on && expires_on < effective_on

      errors.add(:expires_on, "must be on or after effective_on")
    end
end
