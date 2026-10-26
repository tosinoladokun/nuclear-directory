# A directed link between two organizations, e.g. Centrus supplies TerraPower.
# Read it as "from <type> to", e.g. Georgia Power subsidiary_of Southern Company.
# Deal stage (MOU vs signed) goes in the description.
class Relationship < ApplicationRecord
  # A deal row's "what" when it has no deal terms (#559, Design 4.2).
  normalizes :short_phrase, with: ->(text) { text.squish.presence }
  validates :short_phrase, length: { maximum: ShortDescription::MAX }, allow_nil: true
  include Verifiable

  # funds = grants and awards; invests_in = equity;
  # subsidiary_of points from the child to its parent.
  enum :relationship_type, %w[supplies invests_in funds offtake_with subsidiary_of].index_by(&:itself), validate: true

  belongs_to :from_organization, class_name: "Organization", inverse_of: :outgoing_relationships
  belongs_to :to_organization, class_name: "Organization", inverse_of: :incoming_relationships

  validates :relationship_type, uniqueness: { scope: [ :from_organization_id, :to_organization_id ] }

  # Hidden when either company isn't published.
  def self.published
    companies = Organization.published.select(:id)
    verified.where(from_organization_id: companies, to_organization_id: companies)
  end
  validate :not_self_referential
  validate :ends_after_start

  private
    def not_self_referential
      if from_organization_id.present? && from_organization_id == to_organization_id
        errors.add(:to_organization, "can't be the same as the from organization")
      end
    end

    def ends_after_start
      errors.add(:ended_on, "must be on or after started_on") if started_on && ended_on && ended_on < started_on
    end
end
