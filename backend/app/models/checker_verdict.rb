# One nightly checker verdict on a claim (#776), in shadow: DQ reads them, nothing acts on them yet.
class CheckerVerdict < ApplicationRecord
  VERDICTS = %w[approve reject unsure].freeze

  belongs_to :candidate

  validates :verdict, inclusion: { in: VERDICTS }
  validates :field, :reason, :prompt_version, presence: true

  scope :today, ->(now = Time.current) { where(created_at: now.utc.beginning_of_day..) }
end
