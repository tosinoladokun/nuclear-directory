# Up to five other companies a company page links to (#606, Outcome 30 Nov: internal links for indexing): first those
# sharing a tag page the company is in (the more specific list), then those in its category, most connected first.
# Published companies only, never the company itself.
#
#   SimilarCompanies.for(profile) # => [Organization, ...] (at most 5)
class SimilarCompanies
  LIMIT = 5

  def self.for(profile) = new(profile).companies

  def initialize(profile)
    @profile = profile
    @organization = profile.organization
  end

  def companies
    found = []
    pools.each do |listing|
      break if found.size >= LIMIT

      found |= listing.companies.where.not(id: [ @organization.id, *found.map(&:id) ]).limit(LIMIT - found.size).to_a
    end
    found.first(LIMIT)
  end

  private
    # Tag lists first (smallest first: the more specific), then the category's list.
    def pools
      tags = held_tags.sort_by { |tag| Organization.where(id: tag.organization_ids).count }
      lists = tags.map { |tag| DirectoryListing.new(tag: tag.key) }
      lists << DirectoryListing.new(category: @profile.category.key) if @profile.category && !@profile.category.plants
      lists
    end

    def held_tags
      # A tag's list holds its children too (SMR sits under fission), so a held role or technology also puts the company
      # in its parent's tag list, matching Tag#organization_ids.
      roles = @profile.shown_roles.flat_map { |link| [ link.role, link.role.parent ].compact.map { |role| Tag.for_role(role.key) } }
      techs = @profile.technologies.flat_map { |link| [ link.technology, link.technology.parent ].compact.map { |tech| Tag.for_technology(tech.key) } }
      (roles + techs).compact.uniq
    end
end
