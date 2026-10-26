# One matching action by Data Quality's agent (#548): see DataQuality::Matching.
class DqAction < ApplicationRecord
  ACTIONS = %w[same_as subsidiary_of new close].freeze
  BY = "agent:data-quality"

  belongs_to :candidate
  validates :action, inclusion: { in: ACTIONS }
  validates :reason, presence: true

  scope :live, -> { where(undone_at: nil) }
end
