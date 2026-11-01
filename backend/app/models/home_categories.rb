# The home page's category cards (#362): each bucket, then Plants and sites,
# with its count and the three names it shows.
#
#   HomeCategories.cards # => [HomeCategories::Card, ...]
#
# Which three (Tosin, 17 Oct): the companies with the most published,
# sourced links, ties by name. Investors rank by how many companies they
# fund, so a funder with many awards to one company doesn't lead. Plants
# and sites rank by their sourced links. Only records with a public page,
# so no name leads to "Page not found". Never paid placement.
#
# A company shows on one card only (Tosin, 18 Oct): cards fill in display
# order, and each skips the companies an earlier card shows, so the next
# most-linked one takes the spot. The count stays the category's real total.
class HomeCategories
  SHOWN = 3

  # What each card's title says (Tosin, 31 Oct): the full name in Title Case on every width, desktop and phone alike.
  # The category's own name stays in title and aria-label where it differs; the title shrinks to 13px to stay on one line.
  LABELS = {
    "reactor-developers" => "Reactor Developers",
    "fuel" => "Fuel and Materials",
    "components" => "Components and Parts",
    "waste-decommissioning" => "Waste and Decommissioning",
    "utilities" => "Power Plant Owners and Operators",
    "plants" => "Plants and Sites",
    "power-buyers" => "Power Buyers",
    "services" => "Services and Engineering",
    "investors" => "Investors",
    "government-research" => "Government and Research"
  }.freeze

  def self.label(category) = LABELS.fetch(category.key, category.name)

  # records: Organizations or Facilities (sites), in order.
  Card = Data.define(:category, :count, :records) do
    def more? = count > records.size
  end

  def self.cards = new.cards

  def cards
    counts = DirectoryListing.category_counts
    buckets = Category.buckets.select { |category| counts[category.key].to_i.positive? }
    shown = []
    (buckets + [ Category.find("plants") ]).map do |category|
      records = top(category, skip: shown)
      shown.concat(records.map(&:id)) unless category.plants
      Card.new(category:, count: counts[category.key].to_i, records:)
    end
  end

  # skip: ids of companies an earlier card already shows.
  def top(category, skip: [])
    category.plants ? top_plants : top_companies(category, skip)
  end

  private
    def top_companies(category, skip)
      score = category.key == "investors" ? funded_companies_sql : company_links_sql
      Organization.published.where(id: Bucket.organization_ids(category)).where.not(id: skip)
        .select("organizations.*", "(#{score}) AS home_score")
        .order(Arel.sql("home_score DESC"), :name).limit(SHOWN).to_a
    end

    def top_plants
      DirectoryListing.new.public_sites.select("facilities.*", "(#{plant_links_sql}) AS home_score")
        .order(Arel.sql("home_score DESC"), :name).limit(SHOWN).to_a
    end

    def sourced_ids(facts) = facts.where(id: Evidence.where(subject_type: facts.model.name).select(:subject_id)).select(:id).to_sql

    # Links to other companies (either side) and to plants; a framework or
    # non-binding deal adds nothing to the ranking (#487).
    def company_links_sql
      <<~SQL.squish
        (SELECT COUNT(*) FROM relationships r WHERE r.id IN (#{sourced_ids(Relationship.published.signed_or_unstaged)})
          AND (r.from_organization_id = organizations.id OR r.to_organization_id = organizations.id))
        + (SELECT COUNT(*) FROM facility_relationships fr WHERE fr.id IN (#{sourced_ids(FacilityRelationship.published.signed_or_unstaged)})
          AND fr.organization_id = organizations.id)
      SQL
    end

    # Distinct companies it invests in or funds.
    def funded_companies_sql
      <<~SQL.squish
        SELECT COUNT(DISTINCT r.to_organization_id) FROM relationships r
        WHERE r.id IN (#{sourced_ids(Relationship.published.where(relationship_type: %w[invests_in funds]))})
          AND r.from_organization_id = organizations.id
      SQL
    end

    # Links to the site or any of its units.
    def plant_links_sql
      <<~SQL.squish
        SELECT COUNT(*) FROM facility_relationships fr WHERE fr.id IN (#{sourced_ids(FacilityRelationship.published)})
          AND fr.facility_id IN (SELECT u.id FROM facilities u WHERE u.id = facilities.id OR u.parent_id = facilities.id)
      SQL
    end
end
