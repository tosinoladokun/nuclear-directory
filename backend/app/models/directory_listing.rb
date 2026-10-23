# What the directory and search results page lists (#40). Browsing and
# searching are the same thing here: a category, a query and the filters all
# narrow one list. Only published records are listed, and connection counts
# only count published links: a fact is published when it's verified and the
# company or plant it hangs on is published too (see each model's .published),
# so unpublishing a company or plant hides everything that hangs on it.
#
#   listing = DirectoryListing.new(category: "fuel", q: "enrich", state: "TN")
#   listing = DirectoryListing.new(tag: "fusion")  # a tag's list page (#281)
#   listing.companies  # => Organizations, each with #connections_count
#   listing.plants     # => Facilities (sites, not units)
class DirectoryListing
  SORTS = { "name" => "A to Z", "connections" => "Most connected" }.freeze

  attr_reader :category, :tag, :query, :technology, :state, :sort, :role

  # Unknown values are ignored rather than raising: these come from the URL.
  def initialize(category: nil, tag: nil, q: nil, technology: nil, state: nil, sort: nil, role: nil)
    @category = Category.find(category)
    # A tag narrows companies, so it's ignored on Plants and sites.
    @tag = Tag.find(tag) unless @category&.plants
    @query = q.to_s.strip.first(100).presence
    # A filter value that isn't one of the options is dropped, so a stale or
    # mistyped URL can't silently narrow the list behind an "Any" control.
    @technology = technology.to_s.presence&.presence_in(technology_options.map(&:last))
    @state = state.to_s.strip.upcase.presence&.presence_in(state_options)
    @sort = SORTS.key?(sort.to_s) ? sort.to_s : "name"
    # A bucket made of several roles narrows to one of them (Developers:
    # reactor designers or project developers). Any other value is dropped.
    @role = role.to_s.presence&.presence_in(@category.role_keys) if @category && @category.role_keys.size > 1
  end

  # Number of published companies in each bucket, and of plants and sites,
  # for the pills. A company in two buckets counts in both.
  def self.category_counts
    Bucket.counts.merge("plants" => new(category: "plants").plant_scope.count)
  end

  # Each with #connections_count, in the chosen order.
  def companies
    ordered(company_scope.select("organizations.*", "(#{company_connections_sql}) AS connections_count"), "organizations.name")
  end

  # Each site also gets #units_statuses (one per published unit, for
  # units_summary) and #units_capacity_mw, the sum of its operating units'.
  def plants
    ordered(plant_scope.select("facilities.*", "(#{plant_connections_sql}) AS connections_count",
      "ARRAY(#{units_sql("u.status")}) AS units_statuses",
      "(#{units_sql("SUM(u.capacity_mw) FILTER (WHERE u.status = 'operating')")}) AS units_capacity_mw",
      # For the site's icon: its sourced units' reactor types, and whether the
      # site's own facts are sourced, as its page decides (PlantProfile).
      "ARRAY(#{units_sql("u.reactor_type")} AND #{sourced_sql("u.id")}) AS units_reactor_types",
      "(#{sourced_sql("facilities.id")}) AS site_sourced"), "facilities.name")
  end

  # Companies are listed unless the Plants and sites category is chosen.
  def company_scope
    return Organization.none if category&.plants

    scope = Organization.published
    scope = scope.where(id: Bucket.organization_ids(category)) if category
    scope = scope.where(id: tag.organization_ids) if tag
    scope = scope.where(id: Bucket.role_member_ids(role)) if role
    scope = matching_companies(scope) if query
    scope = with_technology(scope) if technology
    scope = scope.where(hq_state: state) if state
    scope
  end

  # Plants show for the Plants and sites category, and alongside companies in
  # search results. Only sites are listed; reactor units sit under them. A
  # site is public when it's verified, or when at least one of its units is
  # published (#73: a site made from NRC units goes public with its first one).
  def plant_scope
    return Facility.none if (category && !category.plants) || tag
    return Facility.none if category.nil? && query.nil?

    scope = public_sites
    scope = matching_plants(scope) if query
    scope = scope.verified.where(state:) if state
    scope = plants_with_technology(scope) if technology
    scope
  end

  def searching? = query.present?
  def filtered? = technology.present? || state.present? || role.present?

  # Filter choices that actually occur in published data.
  # Technologies used by published companies, plants or units, plus their
  # parents (SMR in use offers Fission); then coolant types, which only
  # apply to companies. Only from the kinds of record this listing can show,
  # so every option can match something.
  def technology_options
    @technology_options ||= begin
      companies = Organization.published.select(:id)
      used = [
        (Technology.where(id: OrganizationTechnology.published.where(organization_id: companies).select(:technology_id)) if lists_companies?),
        (Technology.where(id: plant_technology_sources.where.not(technology_id: nil).select(:technology_id)) if lists_plants?)
      ].compact.reduce { |all, one| all.or(one) } || Technology.none
      techs = Technology.where(id: used.select(:id)).or(Technology.where(id: used.select(:parent_id)))
        .order(:name).map { |t| [ t.name, t.key ] }
      coolants = Role.where(parent: Role.find_by(key: "coolant"))
        .where(id: OrganizationRole.published.where(organization_id: companies).select(:role_id))
        .order(:name).map { |r| [ "#{r.name} coolant", r.key ] }
      lists_companies? ? techs + coolants : techs
    end
  end

  # States of published companies and of verified public sites (a pending
  # site's own place isn't public, and units aren't checked), from the kinds
  # of record this listing can show, so every option can match.
  def state_options
    @state_options ||= [ (Organization.published.distinct.pluck(:hq_state) if lists_companies?),
                         (public_sites.verified.distinct.pluck(:state) if lists_plants?) ]
      .compact.flatten.compact_blank.uniq.sort
  end

  # Companies show unless the Plants and sites category is chosen; plants
  # show in that category and alongside companies in search results.
  def lists_companies? = !category&.plants
  def lists_plants? = category ? category.plants : query.present? && tag.nil?

  # Sites the public can see: verified ones, and pending ones with at least
  # one published unit (#73). A rejected or unpublished site never shows.
  def public_sites = Facility.published.where(parent_id: nil)

  # Public sites and the published units under them.
  def public_facilities
    Facility.where(id: public_sites.select(:id)).or(Facility.published.where(parent_id: public_sites.select(:id)))
  end

  # Where a plant's technology can come from, as plants_with_technology reads
  # it: a verified site's own, or a published unit's under a public site.
  def plant_technology_sources
    Facility.where(id: public_sites.verified.select(:id)).or(Facility.published.where(parent_id: public_sites.select(:id)))
  end

  private
    # Name or any alias (compared normalized, as the matcher does); a role or
    # technology whose name or key matches ("SMR", "enrichment"); or any
    # party to a published deal or plant link whose description matches
    # ("HALEU"). Role descriptions aren't searched: they're too general to
    # point at anyone.
    def matching_companies(scope)
      by_role = OrganizationRole.published.joins(:role)
        .where("roles.name ILIKE :q OR roles.key ILIKE :q", q: like(query)).select(:organization_id)
      by_tech = OrganizationTechnology.published.joins(:technology)
        .where("technologies.name ILIKE :q OR technologies.key ILIKE :q", q: like(query)).select(:organization_id)
      deals = Relationship.published.where("relationships.description ILIKE ?", like(query))
      plant_links = FacilityRelationship.published.where("facility_relationships.description ILIKE ?", like(query))
      matches = [ by_role, by_tech, deals.select(:from_organization_id), deals.select(:to_organization_id), plant_links.select(:organization_id) ]

      # A query of only punctuation normalizes to "", which would match every alias.
      normalized = OrganizationAlias.normalize(query)
      matches << OrganizationAlias.where("normalized_alias LIKE ?", like(normalized)).select(:organization_id) if normalized.present?

      matches.reduce(scope.where(*loose_name("organizations.name"))) { |all, ids| all.or(scope.where(id: ids)) }
    end

    # The site's name, a published unit's name ("Vogtle Unit 3" finds Plant
    # Vogtle), a technology of a verified site or published unit ("SMR"), or
    # a link to the site or a unit whose description matches, if the plant
    # page shows that link (PlantProfile#links: published, on a verified site
    # or unit, sourced and current).
    def matching_plants(scope)
      units = Facility.published.where.not(parent_id: nil).where(*loose_name("facilities.name")).select(:parent_id)
      links = FacilityRelationship.published.where("facility_relationships.description ILIKE ?", like(query))
        .where(facility_id: Facility.verified.select(:id))
        .where(id: Evidence.where(subject_type: "FacilityRelationship").select(:subject_id))
        .where("facility_relationships.ended_on IS NULL OR facility_relationships.ended_on > ?", Date.current)
      linked = Facility.where(id: links.select(:facility_id))
      linked_sites = Facility.where(id: linked.select(:id)).or(Facility.where(id: linked.select(:parent_id))).select(:id)
      techs = Technology.where("technologies.name ILIKE :q OR technologies.key ILIKE :q", q: like(query)).select(:id)
      tech_units = Facility.published.where.not(parent_id: nil).where(technology_id: techs).select(:parent_id)
      # Other names a plant goes by ("TMI-1" finds Crane), on the site or a unit.
      # A query of only punctuation normalizes to "", which would match them all.
      normalized = FacilityAlias.normalize(query)
      aliased = normalized.present? ? FacilityAlias.where("normalized_alias LIKE ?", like(normalized)).select(:facility_id) : []
      # A site's own aliases, and those of its published units only (as with unit names).
      alias_sites = Facility.where(id: aliased).or(Facility.where(id: Facility.published.where(id: aliased).select(:parent_id))).select(:id)

      scope.where(*loose_name("facilities.name")).or(scope.where(id: units)).or(scope.where(id: linked_sites))
        .or(scope.verified.where(technology_id: techs)).or(scope.where(id: tech_units)).or(scope.where(id: alias_sites))
    end

    # A technology key (fission, smr) or a coolant sub-role key (molten_salt).
    # Verified sites whose own technology, or any public site whose published
    # unit's, is the chosen one or a sub-technology of it. Coolant is a
    # company role, so it hides plants.
    def plants_with_technology(scope)
      technology_record = Technology.find_by(key: technology)
      return scope.none unless technology_record

      tech_ids = Technology.where(id: technology_record.id).or(Technology.where(parent_id: technology_record.id)).select(:id)
      units = Facility.published.where.not(parent_id: nil).where(technology_id: tech_ids).select(:parent_id)
      scope.verified.where(technology_id: tech_ids).or(scope.where(id: units))
    end

    # A technology includes its sub-technologies: Fission includes SMR.
    def with_technology(scope)
      if (technology_record = Technology.find_by(key: technology))
        tech_ids = Technology.where(id: technology_record.id).or(Technology.where(parent_id: technology_record.id)).select(:id)
        scope.where(id: OrganizationTechnology.published.where(technology_id: tech_ids).select(:organization_id))
      elsif (coolant = Role.where(parent: Role.find_by(key: "coolant")).find_by(key: technology))
        scope.where(id: OrganizationRole.published.where(role: coolant).select(:organization_id))
      else
        scope
      end
    end

    def company_connections_sql
      <<~SQL.squish
        SELECT COUNT(*) FROM relationships r WHERE r.id IN (#{Relationship.published.select(:id).to_sql})
          AND (r.from_organization_id = organizations.id OR r.to_organization_id = organizations.id)
        ) + (
        SELECT COUNT(*) FROM facility_relationships fr WHERE fr.id IN (#{FacilityRelationship.published.select(:id).to_sql})
          AND fr.organization_id = organizations.id
      SQL
    end

    # Links to the site itself or to any of its units.
    def plant_connections_sql
      <<~SQL.squish
        SELECT COUNT(*) FROM facility_relationships fr WHERE fr.id IN (#{FacilityRelationship.published.select(:id).to_sql})
          AND fr.facility_id IN (SELECT u.id FROM facilities u WHERE u.id = facilities.id OR u.parent_id = facilities.id)
      SQL
    end

    # An aggregate over a site's published units.
    def sourced_sql(id) = "EXISTS (SELECT 1 FROM evidence e WHERE e.subject_type = 'Facility' AND e.subject_id = #{id})"

    def units_sql(aggregate)
      "SELECT #{aggregate} FROM facilities u WHERE u.parent_id = facilities.id " \
        "AND u.id IN (#{Facility.published.where.not(parent_id: nil).select(:id).to_sql})"
    end

    # When searching, names (or a company's aliases) that start with the
    # query come first, then names that contain it, then matches through a
    # role, technology or deal; the chosen sort orders within each band.
    def ordered(scope, name_column)
      scope = scope.order(relevance_sql(name_column, aliases: name_column == "organizations.name")) if query
      sort == "connections" ? scope.order(Arel.sql("connections_count DESC"), name_column) : scope.order(name_column)
    end

    def relevance_sql(name_column, aliases: false)
      prefix = "#{ActiveRecord::Base.sanitize_sql_like(query)}%"
      Arel.sql(ActiveRecord::Base.sanitize_sql_array(
        [ "CASE WHEN #{name_column} ILIKE ? OR #{alias_match_sql(aliases, :prefix)} THEN 0 " \
          "WHEN #{name_column} ILIKE ? OR #{alias_match_sql(aliases, :contains)} THEN 1 ELSE 2 END",
          prefix, like(query) ]
      ))
    end

    # A company alias that starts with or contains the query, compared
    # normalized as search does ("Kairos Power, LLC").
    def alias_match_sql(aliases, position)
      normalized = OrganizationAlias.normalize(query)
      return "FALSE" unless aliases && normalized.present?

      escaped = ActiveRecord::Base.sanitize_sql_like(normalized)
      pattern = position == :prefix ? "#{escaped}%" : "%#{escaped}%"
      ActiveRecord::Base.sanitize_sql_array([
        "EXISTS (SELECT 1 FROM organization_aliases oa WHERE oa.organization_id = organizations.id AND oa.normalized_alias LIKE ?)", pattern
      ])
    end

    def like(text) = "%#{ActiveRecord::Base.sanitize_sql_like(text.to_s)}%"

    # A name matches the search as typed, or with spacing and punctuation
    # ignored ("next era" finds NextEra), or with every word of it somewhere
    # in the name ("brown ferry" finds Browns Ferry) (#431).
    def loose_name(column)
      compact = query.downcase.gsub(/[^a-z0-9]/, "")
      words = query.downcase.scan(/[a-z0-9]+/).select { |word| word.length >= 2 }
      sql = [ "#{column} ILIKE ?" ]
      binds = [ like(query) ]
      if compact.length >= 3
        sql << "regexp_replace(lower(#{column}), '[^a-z0-9]', '', 'g') LIKE ?"
        binds << like(compact)
      end
      if words.size > 1
        sql << "(#{([ "#{column} ILIKE ?" ] * words.size).join(' AND ')})"
        binds.concat(words.map { |word| like(word) })
      end
      [ sql.join(" OR "), *binds ]
    end
end
