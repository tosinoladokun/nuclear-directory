# One open or resolved alert of the autopilot (#811), by key. See Autopilot::Alert.
class AutopilotAlert < ApplicationRecord
  validates :key, :title, :opened_at, presence: true

  scope :open, -> { where(resolved_at: nil) }

  def open? = resolved_at.nil?
end
