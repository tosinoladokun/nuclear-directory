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
      @cited[fact] = citations.cite(fact.evidence)
    end
end
