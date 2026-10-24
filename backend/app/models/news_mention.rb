# Which company or plant a news item is about (#137). A plant mention points
# at its site (a unit's news is its site's).
class NewsMention < ApplicationRecord
  SUBJECT_TYPES = %w[Organization Facility].freeze

  belongs_to :news_item
  belongs_to :subject, polymorphic: true

  validates :subject_type, inclusion: { in: SUBJECT_TYPES }
  validates :subject_id, uniqueness: { scope: %i[news_item_id subject_type] }
end
