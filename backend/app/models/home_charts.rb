# The charts on homepage B (#909): one large and two small cards per visit, each a question about the industry
# answered from the directory's published, sourced facts (the same rules as the buckets, Bucket). Each chart's data is
# built once per data version.
#
#   HomeCharts.set_for(request) # => [:operators, :buyers, :newest] (large first)
#   HomeCharts.data(:operators) # => [{ name:, slug:, count: }, ...]
#
# Which set: each visitor gets one set a day and a different one the next day (Tosin, 25 Nov: never the same set
# twice in a row, and no cookie). The set's index is a hash of the visitor's IP address and browser plus the day
# number, so it moves on by one each day. The hash is only used to pick the set: it's never stored or sent.
#
# The plants map waits for coordinates (PM, 25 Nov); until then the sets leave it out.
class HomeCharts
  SETS = [ %i[fuel newest categories], %i[operators buyers owners] ].freeze

  FUEL_STEPS = %w[mining conversion enrichment fabrication].freeze
  FUEL_NAMES = 6
  OPERATORS = 8
  SHOWN = 5
  NEWEST = 4
  SOURCE_DOMAINS = 3

  def self.set_for(request, day: Date.current)
    digest = OpenSSL::HMAC.digest("SHA256", Rails.application.key_generator.generate_key("home-charts", 32),
      [ request.remote_ip, request.user_agent.to_s ].join("\n"))
    SETS[(digest.unpack1("N") + day.jd) % SETS.size]
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { feature: "home_charts" })
    SETS.first
  end

  # The visitor's set with each chart's data, [[key, data], ...], large first. A set with a chart that has nothing to
  # show gives way to the next set; nil when no set is whole.
  # data: how a chart's data is read (tests pass their own).
  def self.cards_for(request, day: Date.current, data: method(:data))
    first = SETS.index(set_for(request, day:))
    SETS.rotate(first).each do |set|
      cards = set.map { |key| [ key, data.call(key) ] }
      return cards if cards.all? { |_, value| shown?(value) }
    end
    nil
  end

  def self.shown?(value)
    case value
    in { steps: } then steps.any? { |step| step[:companies].any? }
    in { rows: } then rows.any?
    in { owners: } then owners.size > 1
    in Array then value.any?
    else false
    end
  end

  # A chart's data, plain values only so the cache can hold it. Each chart's source line names the real domains behind
  # its facts, the most used first (sources: { domains: [...], more: true/false }).
  def self.data(key)
    Rails.cache.fetch([ "home-charts/v1", key, DataVersion.current ]) { new.public_send(key) }
  end

  # Where US reactor fuel comes from: each step with its count and the most connected companies at it.
  def fuel
    roles = Role.where(key: FUEL_STEPS)
    steps = FUEL_STEPS.map do |step|
      scope = Organization.published.where(id: Bucket.role_member_ids(step))
      { step:, count: scope.count, companies: HomeCategories.new.most_connected(scope, FUEL_NAMES).map { |org| company(org) } }
    end
    shown = steps.flat_map { |step| step[:companies].map { |row| row[:id] } }
    { steps:, sources: sources(sourced(OrganizationRole.published.where(role: roles, organization_id: shown))) }
  end

  # Who runs the most US plants: operators by the operating power plants (sites) they currently operate.
  def operators
    links = current(sourced(FacilityRelationship.published.operates)).where(organization_id: Organization.published.select(:id))
    links = links.where(facility_id: operating_reactors.select(:id)).or(links.where(facility_id: operating_reactors.where.not(parent_id: nil).select(:parent_id)))
    counts = links.joins(:facility).group(:organization_id).count(Arel.sql("DISTINCT COALESCE(facilities.parent_id, facilities.id)"))
    rows = ranked(counts, OPERATORS)
    { rows:, sources: sources(links.where(organization_id: rows.map { |row| row[:id] })) }
  end

  # Who buys nuclear power: buyers by their sourced, signed power deals (a framework or MoU doesn't count).
  def buyers
    buyers = Organization.published.where(id: Bucket.organization_ids(Category.find("power-buyers"))).select(:id)
    deals = sourced(Relationship.published.offtake_with.signed_or_unstaged).where(from_organization_id: buyers)
    plant_deals = sourced(FacilityRelationship.published.offtakes_from.signed_or_unstaged).where(organization_id: buyers)
    counts = deals.group(:from_organization_id).count.merge(plant_deals.group(:organization_id).count) { |_, a, b| a + b }
    rows = ranked(counts, SHOWN)
    ids = rows.map { |row| row[:id] }
    { rows:, sources: sources(deals.where(from_organization_id: ids), plant_deals.where(organization_id: ids)) }
  end

  # What the companies do: each category with companies, by its count, and how many companies in all.
  def categories
    counts = Bucket.counts
    rows = Category.buckets.filter_map { |category| { key: category.key, name: category.list_name, count: counts[category.key] } if counts[category.key].positive? }
    { rows: rows.sort_by { |row| [ -row[:count], row[:name] ] }, total: DirectoryListing.new.company_scope.count }
  end

  # Newest in the directory: the latest facts a person approved, as What's new lists them, with the day and source.
  def newest
    Updates.new.entries(limit: NEWEST).map do |entry|
      { title: entry.title, page: entry.page, date: entry.at.to_date, domain: domain(entry.source_url) }
    end
  end

  # Who owns a plant: the public plant with the most owners, where every current, sourced owns link states a share
  # and the shares add up to 100%; with the company that runs it.
  def owners
    links = current(sourced(FacilityRelationship.published.where(relationship_type: "owns")))
      .where(organization_id: Organization.published.select(:id), facility_id: Facility.published.where(parent_id: nil).select(:id))
      .includes(:organization, :facility)
    plant, shares = links.group_by(&:facility)
      .select { |_, rows| rows.size > 1 && rows.all?(&:ownership_pct) && (rows.sum(&:ownership_pct) - 100).abs <= 0.5 }
      .max_by { |facility, rows| [ rows.size, facility.name ] }
    return {} unless plant

    operator = current(sourced(FacilityRelationship.published.operates)).where(organization_id: Organization.published.select(:id))
      .where(facility_id: Facility.where(id: plant.id).or(Facility.published.where(parent_id: plant.id)).select(:id))
      .includes(:organization).map(&:organization).uniq
    runs = operator.one? && shares.none? { |row| row.organization_id == operator.first.id } ? company(operator.first) : nil
    { plant: plant.name, slug: plant.slug, operator: runs,
      owners: shares.sort_by { |row| [ -row.ownership_pct, row.organization.name ] }.map { |row| company(row.organization).merge(pct: row.ownership_pct.to_f) },
      sources: sources(FacilityRelationship.where(id: shares.map(&:id))) }
  end

  private
    def company(org) = { id: org.id, name: org.name, short: org.short_name, slug: org.slug }

    def ranked(counts, limit)
      orgs = Organization.where(id: counts.keys).index_by(&:id)
      counts.map { |id, count| company(orgs[id]).merge(count:) }.sort_by { |row| [ -row[:count], row[:name] ] }.first(limit)
    end

    # The domains of the sources behind these facts, the most used first: the first three, and whether there are more.
    def sources(*facts)
      urls = facts.flat_map do |scope|
        Source.joins(:evidence).where(evidence: { subject_type: scope.model.name, subject_id: scope.select(:id) }).pluck(:url)
      end
      tally = urls.filter_map { |url| domain(url) }.tally.sort_by { |name, n| [ -n, name ] }.map(&:first)
      { domains: tally.first(SOURCE_DOMAINS), more: tally.size > SOURCE_DOMAINS }
    end

    def domain(url)
      URI.parse(url.to_s).host&.delete_prefix("www.")
    rescue URI::InvalidURIError
      nil
    end

    def operating_reactors = sourced(Facility.verified.where(id: Facility.published.select(:id), facility_type: "power_reactor", status: "operating"))

    def sourced(facts) = facts.where(id: Evidence.where(subject_type: facts.model.name).select(:subject_id))

    def current(links)
      links.where("facility_relationships.started_on IS NULL OR facility_relationships.started_on <= ?", Date.current)
        .where("facility_relationships.ended_on IS NULL OR facility_relationships.ended_on > ?", Date.current)
    end
end
