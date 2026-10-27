# How an organization is tied to a facility: owns, operates, vendor_for or
# offtakes_from. ownership_pct is only meaningful for owns.
class FacilityRelationship < ApplicationRecord
  # A deal row's "what" when it has no deal terms (#559, Design 4.2).
  normalizes :short_phrase, with: ->(text) { text.squish.presence }
  validates :short_phrase, length: { maximum: ShortDescription::MAX }, allow_nil: true
  include Verifiable
  include DealStage

  enum :relationship_type, %w[owns operates vendor_for offtakes_from].index_by(&:itself), validate: true

  belongs_to :organization
  belongs_to :facility

  validates :relationship_type, uniqueness: { scope: [ :organization_id, :facility_id ] }

  # Hidden when its company or plant isn't published.
  def self.published
    verified.where(organization_id: Organization.published.select(:id), facility_id: Facility.published.select(:id))
  end
  validates :ownership_pct, numericality: { in: 0..100 }, allow_nil: true
  validate :ownership_pct_only_for_owns
  validate :ends_after_start

  private
    def ownership_pct_only_for_owns
      errors.add(:ownership_pct, "only applies to owns") if ownership_pct.present? && !owns?
    end

    def ends_after_start
      errors.add(:ended_on, "must be on or after started_on") if started_on && ended_on && ended_on < started_on
    end
end
