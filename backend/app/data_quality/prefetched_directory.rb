# A DirectoryClient for one page that reads many claims at once (Tosin's
# inbox, #1008): the records the claims are about, and which companies have a
# sourced role, are read up front in a few queries, so asking about each claim
# doesn't query again. Anything it wasn't given is asked of the directory as
# usual. Only for reading: a write isn't seen by what was read before it.
class DataQuality::PrefetchedDirectory < SimpleDelegator
  def initialize(directory = DataQuality::DirectoryClient.new)
    super
    @facts = {}
    @attached = {}
    @sourced_roles = {}
    @by_domain = {}
    @sites = {}
  end

  # Reads the subjects of these claims, and the sourced roles of the companies among them.
  def prefetch(candidates)
    by_type = candidates.select(&:subject_id).group_by(&:subject_type)
    by_type.each do |type, claims|
      next unless fact_kinds.include?(type.to_s.underscore)

      ids = claims.map(&:subject_id).uniq - @facts.fetch(type, {}).keys
      found = __getobj__.facts(type:, ids:)
      (@facts[type] ||= {}).merge!(ids.index_with { |id| found[id] })
      next unless %w[Organization Facility].include?(type)

      ids = claims.map(&:subject_id).uniq - @attached.fetch(type, {}).keys
      found = __getobj__.attached_records(type:, ids:)
      (@attached[type] ||= {}).merge!(ids.index_with { |id| found[id] })
    end
    # The companies their websites' domains belong to, which a restated website is checked against.
    domains = candidates.filter_map { |claim| domain_from(claim.payload.to_h["website"]) if claim.kind == "organization" && claim.payload.to_h["website"].present? }.uniq - @by_domain.keys
    found = __getobj__.organizations_by_domain(domains)
    domains.each { |domain| @by_domain[domain] = found[domain] }
    # The sites EIA's enrichment of units names by plant ID.
    plants = candidates.filter_map { |claim| claim.payload.to_h.dig(DataQuality::DirectoryClient::ENRICHMENT_KEY, "eia_plant_id").presence&.to_s }.uniq - @sites.keys
    found = __getobj__.sites_by_plant_id(plants)
    plants.each { |plant| @sites[plant] = found[plant] }
    # And those sites' own records, which a unit's change names (Copilot).
    site_ids = found.values.map(&:id).uniq - @facts.fetch("Facility", {}).keys
    if site_ids.any?
      sites = __getobj__.facts(type: "Facility", ids: site_ids)
      (@facts["Facility"] ||= {}).merge!(site_ids.index_with { |id| sites[id] })
    end
    companies = by_type.fetch("Organization", []).map(&:subject_id).uniq - @sourced_roles.keys
    with_role = __getobj__.sourced_role_ids(companies)
    companies.each { |id| @sourced_roles[id] = with_role.include?(id) }
    self
  end

  def organization(id: nil, name: nil, domain: nil, sec_cik: nil, eia_utility_id: nil)
    if domain && [ id, name, sec_cik, eia_utility_id ].all?(&:nil?) && @by_domain.key?(normalized = domain_from(domain) || domain)
      return @by_domain[normalized]
    end

    __getobj__.organization(id:, name:, domain:, sec_cik:, eia_utility_id:)
  end

  def fact(type:, id:)
    cached = @facts[type.to_s]
    cached&.key?(id) ? cached[id] : __getobj__.fact(type:, id:)
  end

  def attached_record(candidate)
    return unless candidate.subject_id
    # A link, role or term is its fact, as the directory reads it; read through this cache (Copilot).
    return fact(type: candidate.subject_type, id: candidate.subject_id) unless %w[Organization Facility].include?(candidate.subject_type)

    cached = @attached[candidate.subject_type.to_s]
    cached&.key?(candidate.subject_id) ? cached[candidate.subject_id] : __getobj__.attached_record(candidate)
  end

  def site_for_unit(candidate)
    plant = candidate.payload.to_h.dig(DataQuality::DirectoryClient::ENRICHMENT_KEY, "eia_plant_id").presence&.to_s or return
    units = @attached.fetch("Facility", {})
    return __getobj__.site_for_unit(candidate) unless units.key?(candidate.subject_id) && @sites.key?(plant)

    unit = units[candidate.subject_id] or return
    DataQuality::DirectoryClient.unit_site(unit) { @sites[plant] }
  end

  # From the company's prefetched name and aliases, compared as known_name? does (#1008).
  def known_name?(type:, id:, name:)
    values = (@facts.dig("Organization", id)&.values if type.to_s == "Organization")
    return __getobj__.known_name?(type:, id:, name:) unless values

    wanted = normalized_name(type:, name:)
    [ values["name"], *Array(values["aliases"]) ].compact.any? { |known| normalized_name(type:, name: known) == wanted }
  end

  def sourced_role?(organization_id)
    @sourced_roles.key?(organization_id) ? @sourced_roles[organization_id] : __getobj__.sourced_role?(organization_id)
  end
end
