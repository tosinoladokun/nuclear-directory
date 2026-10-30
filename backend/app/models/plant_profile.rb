# Everything the power plant page shows (#43), verified and sourced facts
# only. A page is for a site the public can see (DirectoryListing#public_sites);
# its verified, sourced units are listed on it. A pending site shows because
# a unit is verified, so its own details (type, status, place) stay hidden
# until the site itself is verified and has a source.
#
# Sources are numbered once, in reading order (the site, its companies,
# then its units), so chips and the source list agree.
class PlantProfile
  # Owners first, then the operator, the reactor developer and power buyers.
  LINK_ORDER = %w[owns operates vendor_for offtakes_from].freeze

  attr_reader :site, :citations

  # nil unless the site is public.
  def self.find(slug)
    site = Facility.published.where(parent_id: nil).find_by(slug:)
    new(site) if site
  end

  def initialize(site)
    @site = site
    @citations = CitationIndex.new
    @cited = {}
    number_sources
  end

  delegate :name, :slug, to: :site

  # [[number, source], ...] for a fact on this page.
  def citations_for(fact) = @cited.fetch(fact) { [] }

  # The site's own fields show once the site is verified and sourced.
  def site_facts? = defined?(@site_facts) ? @site_facts : (@site_facts = site.verified? && site.evidence.any?)
  def facility_type = (site.facility_type if site_facts?)
  def status = (site.status if site_facts?)
  def city = (site.city if site_facts?)
  def state = (site.state if site_facts?)
  def nrc_docket = (site.nrc_docket if site_facts?)

  def units
    @units ||= Facility.published.where(parent: site).includes(:technology, evidence: :source).order(:name).select { |unit| unit.evidence.any? }
  end

  # Current, published links (company and plant published) to the site, once
  # verified, or one of its listed units. An ended link isn't shown as current.
  def links
    @links ||= FacilityRelationship.published.where(facility: [ (site if site.verified?), *units ].compact)
      .where("facility_relationships.ended_on IS NULL OR facility_relationships.ended_on > ?", Date.current)
      .includes(:organization, :facility, evidence: :source).to_a
      .select { |link| link.evidence.any? }
      .sort_by { |link| [ LINK_ORDER.index(link.relationship_type), link.organization.name, link.facility.name ] }
  end

  # One company with what it does here: its links collapsed into one row, with the units they cover
  # and the share it states (only when every link states the same one; never estimated).
  Party = Struct.new(:organization, :links, :units, :share, keyword_init: true)

  # The companies behind links of one type, one row each, in link order.
  def parties_for(type)
    links.select { |link| link.relationship_type == type }.group_by(&:organization).map do |organization, own|
      # A share shows only when every link states the same one: a unit with none stated breaks it.
      shares = own.map(&:ownership_pct).uniq
      Party.new(organization:, links: own, units: own.map(&:facility).reject { |facility| facility == site }.uniq, share: (shares.first if shares.size == 1))
    end
  end

  # "units 3 and 4", "units 1 to 4", "unit 2": what a party's links cover, from the unit names' numbers; nil when
  # a link names the site itself, or a name has no number.
  STATED_UNITS = /\bunits?\s+\d+(?:\s*(?:,|and|&|to|–|-)\s*\d+)*/i

  def units_phrase(party)
    # A link to the site itself names no unit; its own words may still state which units it covers (never inferred).
    if party.units.empty? || party.links.any? { |link| link.facility == site }
      return party.links.filter_map { |link| link.description.to_s[STATED_UNITS] }.first&.downcase&.squish
    end

    numbers = party.units.map { |unit| unit.name[/(\d+)\s*\z/, 1]&.to_i }
    return if numbers.any?(&:nil?)

    numbers = numbers.sort.uniq
    return "unit #{numbers.first}" if numbers.one?

    list = if numbers.each_cons(2).all? { |a, b| b == a + 1 } && numbers.size > 2 then "#{numbers.first} to #{numbers.last}"
    else "#{numbers[0..-2].join(", ")} and #{numbers.last}"
    end
    "units #{list}"
  end

  # The first category of a company, looked up once for all the page's parties.
  def party_category(organization)
    @party_categories ||= Bucket.firsts(links.map(&:organization))
    @party_categories[organization.id]
  end

  # The sources behind a party's row.
  def party_citations(party) = party.links.flat_map { |link| citations_for(link) }.uniq(&:first)

  def companies_for(type) = links.select { |link| link.relationship_type == type }.map(&:organization).uniq

  # Only links already in effect: the page shows a scheduled one as "Starts …",
  # but a one-line summary would state it as current (#246).
  def current_companies_for(type)
    links.select { |link| link.relationship_type == type && (link.started_on.nil? || link.started_on <= Date.current) }
      .map(&:organization).uniq
  end

  def technologies
    [ (site.technology if site_facts?), *units.map(&:technology) ].compact.uniq.map(&:name)
  end

  def reactor_types
    [ (site.reactor_type if site_facts?), *units.map(&:reactor_type) ].compact_blank.uniq
  end

  # Operating capacity only (PM, 16 Oct): a standalone reactor's own figure
  # while it's operating, or the sum of the operating units' when each is
  # known. Anything shut down, being decommissioned, not operating or of
  # unknown status isn't counted.
  def capacity_mw
    return (site.capacity_mw if site.operating?) if own_capacity?
    capacities = operating_units.map(&:capacity_mw)
    capacities.sum if capacities.any? && capacities.none?(&:nil?)
  end

  def operating_units = units.select(&:operating?)

  # True when some units aren't counted in capacity_mw.
  def capacity_leaves_out_units? = !own_capacity? && operating_units.size < units.size

  # A standalone record that carries its own capacity (DATA.md: until its EIA site exists).
  def own_capacity? = site_facts? && site.capacity_mw.present?

  # When the site was checked, or (for a pending site) its latest unit.
  def verified_at = site.verified? ? site.verified_at : units.filter_map(&:verified_at).max

  # Fields DESIGN.md marks "must" that this plant doesn't have yet.
  def missing_fields
    [ ("Type" unless facility_type),
      ("Status" unless status),
      ("Location" if city.blank? && state.blank?),
      ("NRC docket" if nrc_docket.blank? && units.none? { |unit| unit.nrc_docket.present? }),
      ("Owner" if companies_for("owns").empty?),
      ("Operator" if facility_type == "power_reactor" && companies_for("operates").empty?) ].compact
  end

  # The site's own evidence backs its type, status and place.
  def site_citations = site_facts? ? citations_for(site) : []

  # The facts the line under the key facts may name (#407): of :docket and
  # :location, those shown that one of the site's own quotes states. Checked
  # as the page is drawn, so a value edited since stops being named. Type and
  # status wait for #398.
  def quoted_facts
    @quoted_facts ||= begin
      quotes = site_facts? ? site.evidence.map(&:quote).compact : []
      [ (:docket if Directory::QuoteBacking.docket?(quotes, nrc_docket)),
        (:location if Directory::QuoteBacking.place?(quotes, city:, state:)) ].compact
    end
  end

  private
    def number_sources
      cite(site) if site_fields_shown?
      links.each { |link| cite(link) }
      units.each { |unit| cite(unit) }
    end

    # The site is cited only when the page shows one of its own fields, so
    # the source list never starts with a source nothing points to.
    def site_fields_shown?
      site_facts? && [ site.facility_type, site.status, site.city, site.state, site.nrc_docket,
                       site.technology_id, site.reactor_type, site.capacity_mw ].any?(&:present?)
    end

    def cite(fact)
      @cited[fact] = citations.cite(fact.evidence, checked: fact.try(:verified_at))
    end
end
