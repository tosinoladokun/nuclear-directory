# One award, offtake or funding round under its link (#256). The link says
# who deals with whom ("U.S. Department of Energy funds X-energy"); each term
# is one instance of it, with its own amount, dates and source, so awards,
# deals and rounds can be sorted, charted and exported. Written through
# Directory::FactWriter (kind :deal_term).
class DealTerm < ApplicationRecord
  include Verifiable

  # A Form D round names no investors, so it sits on the company itself
  # (PM, 18 Oct 2026, #129): link_type "Organization", rounds only.
  LINK_TYPES = %w[Relationship FacilityRelationship Organization].freeze

  enum :term_type, %w[award offtake funding_round].index_by(&:itself), validate: true
  enum :status, %w[announced signed active completed terminated].index_by(&:itself), validate: { allow_nil: true },
    prefix: :status

  # The form of agreement (#256, #255). A signed power deal is counted:
  # a PPA, supply agreement or tariff subscription that's signed, active or
  # completed, with no open condition. The rest (development agreements,
  # prepayments, frameworks, MOUs, letters of intent, options, preorders)
  # are listed by stage (docs/DATA.md section 2).
  AGREEMENTS = %w[ppa supply_agreement tariff_subscription development_agreement prepayment framework mou loi option preorder].freeze
  COUNTED_AGREEMENTS = %w[ppa supply_agreement tariff_subscription].freeze
  COUNTED_STATUSES = %w[signed active completed].freeze
  validates :agreement, inclusion: { in: AGREEMENTS }, allow_nil: true
  validates :firm_mw, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :term_years, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  normalizes :conditions, with: ->(text) { text.squish.presence }

  # Optional here so an unknown link_type is a validation error (the
  # inclusion check below), never a NameError resolving it.
  belongs_to :link, polymorphic: true, optional: true

  # A blank ID is no ID: lookup, validation and the unique index agree.
  normalizes :external_id, with: ->(id) { id.strip.presence }

  validates :link_type, inclusion: { in: LINK_TYPES }
  validates :link, presence: true, if: -> { LINK_TYPES.include?(link_type) }
  validates :external_id, uniqueness: { scope: %i[link_type link_id term_type] }, allow_nil: true
  validates :amount_usd, :amount_offered_usd, :capacity_mw, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
  validates :term_type, inclusion: { in: %w[funding_round], message: "on a company itself must be a funding round" },
    if: -> { link_type == "Organization" }
  validates :amount_usd, :starts_on, :external_id, presence: true, if: :award?
  validate :what_an_offtake_needs, if: :offtake?
  validate :what_a_round_needs, if: :funding_round?
  validate :ends_after_start

  # Public with its link: verified, and the link it belongs to is published.
  def self.published
    verified.where(link_type: "Relationship", link_id: Relationship.published.select(:id))
      .or(verified.where(link_type: "FacilityRelationship", link_id: FacilityRelationship.published.select(:id)))
      .or(verified.where(link_type: "Organization", link_id: Organization.published.select(:id)))
  end

  # A signed power deal, in the data piece's headline count: one still
  # waiting on a condition (an approval) is "signed, pending" instead.
  def counted? = COUNTED_AGREEMENTS.include?(agreement) && COUNTED_STATUSES.include?(status) && conditions.blank?

  private
    # A deal that can be counted states its size; one listed by stage (a
    # framework, an option…) may state none, and then none is filled in.
    def what_an_offtake_needs
      return unless agreement.nil? || COUNTED_AGREEMENTS.include?(agreement)

      errors.add(:base, "an offtake needs capacity_mw or amount_usd") if capacity_mw.nil? && amount_usd.nil?
    end

    def what_a_round_needs
      errors.add(:base, "a funding round needs amount_usd or round") if amount_usd.nil? && round.blank?
    end

    def ends_after_start
      errors.add(:ends_on, "must be on or after starts_on") if starts_on && ends_on && ends_on < starts_on
    end
end
