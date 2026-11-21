# A proposal from Data Quality to take a public fact off (#863 part 2), for
# Tosin's Yes or No in Today, grouped by batch. Yes unpublishes the fact
# (reversible: Put back); No keeps it and records that. Never a delete.
class TakeoffProposal < ApplicationRecord
  TYPES = %w[Organization Facility OrganizationRole OrganizationTechnology Relationship FacilityRelationship DealTerm LicensingStage NewsItem].freeze

  validates :subject_type, inclusion: { in: TYPES }
  validates :reason, :batch, :proposed_by, presence: true
  validates :status, inclusion: { in: %w[pending taken_off kept] }

  scope :pending, -> { where(status: "pending") }

  def subject = subject_type.constantize.find_by(id: subject_id)

  # Yes: take it off (unpublish) as `by`; No: keep it. Recorded either way.
  # Returns the errors ([] when done).
  def decide!(yes:, by:)
    return [ "already decided" ] unless status == "pending"

    if yes
      result = DataQuality::Review.unpublish(type: subject_type, id: subject_id, by:, reason: "Data Quality: #{reason}")
      return Array(result.errors) unless result.ok?
    end
    update!(status: yes ? "taken_off" : "kept", decided_by: by, decided_at: Time.current)
    []
  end
end
