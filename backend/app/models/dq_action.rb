# One matching action by Data Quality's agent (#548): see DataQuality::Matching.
class DqAction < ApplicationRecord
  ACTIONS = %w[same_as subsidiary_of new close recommend propose_role].freeze
  BY = "agent:data-quality"

  belongs_to :candidate
  validates :action, inclusion: { in: ACTIONS }
  validates :reason, presence: true
  validates :request_key, uniqueness: true, allow_nil: true

  scope :live, -> { where(undone_at: nil) }
end
