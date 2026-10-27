# Which companies are in each bucket (docs/DATA.md section 4, #281). A
# company is in every bucket its published, sourced roles and links put it
# in, the facts its page shows; no bucket is stored or chosen by a person.
#
#   Bucket.organization_ids(Category.find("utilities")) # => a subquery of ids
#   Bucket.for(organization)  # => its buckets (Categories), in display order
#   Bucket.counts             # => { "fuel" => 11, ... }, published companies
#
# Roles count with their child roles (enrichment under fuel). The link rules:
#   Power plant owners and operators: a current owns or operates link to an
#     operating power reactor, or to a site with one.
#   Power buyers: the buyer in a power deal (offtake_with, or offtakes_from a
#     plant). A power plant owner or operator never is one.
#   Investors: the funder in an invests_in or funds link. A government
#     agency, national lab or university never is one.
# The reactor behind an operating plant must itself be public: published,
# verified and sourced, as its page shows it.
# Totals count companies, never the sum of buckets: a company can be in
# several.
class Bucket
  GOVERNMENT_ROLES = %w[government_agency national_lab university].freeze

  def self.organization_ids(category)
    return Organization.none.select(:id) if category.nil? || category.plants

    new.ids(category)
  end

  # The first category (in display order) of each of several companies, in one pass: { id => Category },
  # absent for a company in none. Nine queries however many companies, instead of nine each.
  def self.firsts(organizations)
    ids = organizations.map(&:id).uniq
    finder = new
    found = {}
    Category.buckets.each do |category|
      Organization.where(id: ids).where(id: finder.ids(category)).pluck(:id).each { |id| found[id] ||= category }
    end
    found
  end

  def self.for(organization)
    finder = new
    Category.buckets.select { |category| Organization.where(id: organization.id).where(id: finder.ids(category)).exists? }
  end

  # Ids, as a subquery, of companies with this role or one of its sub-roles,
  # published and sourced as the buckets count it: a bucket's sub-type
  # filter (Developers: ?role=reactor_vendor, Tosin 21 Oct).
  def self.role_member_ids(key) = new.send(:with_roles, [ key.to_s ])

  def self.counts
    finder = new
    Category.buckets.to_h { |category| [ category.key, Organization.published.where(id: finder.ids(category)).count ] }
  end

  # Organization ids, as a subquery, of published companies in the bucket.
  def ids(category)
    scopes = [ (with_roles(category.role_keys) if category.role_keys.any?), (send(category.links) if category.links) ].compact
    members = scopes.map { |ids| Organization.published.where(id: ids) }.reduce { |all, one| all.or(one) } || Organization.none
    excluded = exclusion(category)
    (excluded ? members.where.not(id: excluded) : members).select(:id)
  end

  private
    def with_roles(keys)
      roles = Role.where(key: keys)
      role_ids = Role.where(id: roles.select(:id)).or(Role.where(parent_id: roles.select(:id))).select(:id)
      sourced(OrganizationRole.published.where(role_id: role_ids)).select(:organization_id)
    end

    # Who can't be in a bucket whatever their roles or links say (DATA.md).
    def exclusion(category)
      case category.key
      when "power-buyers" then ids(Category.find("utilities"))
      when "investors" then with_roles(GOVERNMENT_ROLES)
      end
    end

    def operating_plants
      reactors = sourced(Facility.verified.where(id: Facility.published.select(:id), facility_type: "power_reactor", status: "operating"))
      plants = Facility.where(id: reactors.select(:id)).or(Facility.where(id: Facility.published.where(id: reactors.where.not(parent_id: nil).select(:parent_id))))
      current(sourced(FacilityRelationship.published).where(relationship_type: %w[owns operates], facility_id: plants.select(:id)))
        .select(:organization_id)
    end

    def power_deals
      # A framework or other non-binding deal alone doesn't make a power buyer (#487).
      Organization.where(id: sourced(Relationship.published.offtake_with.signed_or_unstaged).select(:from_organization_id))
        .or(Organization.where(id: sourced(FacilityRelationship.published.offtakes_from.signed_or_unstaged).select(:organization_id))).select(:id)
    end

    def investments
      Organization.where(id: sourced(Relationship.published.where(relationship_type: %w[invests_in funds])).select(:from_organization_id)).select(:id)
    end

    # Facts with at least one source.
    def sourced(facts) = facts.where(id: Evidence.where(subject_type: facts.model.name).select(:subject_id))

    # In effect today: started (or no start date) and not yet ended.
    def current(links)
      links.where("facility_relationships.started_on IS NULL OR facility_relationships.started_on <= ?", Date.current)
        .where("facility_relationships.ended_on IS NULL OR facility_relationships.ended_on > ?", Date.current)
    end
end
