# One finished step on the admin's Today page (#373). See Today.
class TodayStep < ApplicationRecord
  STEPS = %w[crawl list review left].freeze
  NOTES = %w[no_list].freeze

  validates :on, presence: true
  # One row per day and step: the unique index enforces it, so marking twice finds the first.
  validates :step, inclusion: { in: STEPS }
  validates :done_by, format: { with: /\Ahuman:\S+\z/ }
  validates :note, inclusion: { in: NOTES }, allow_nil: true
end
