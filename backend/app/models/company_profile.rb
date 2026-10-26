# Everything the company page shows (#42), published and sourced facts only
# (VOICE.md: if we can't source it, we don't publish it). Published means each
# model's .published scope (#87, #98): verified, and what it hangs on is
# published too, so unpublishing a company, partner or plant hides its facts
# here. Deals count only when the other company is published; plant links
# only when the plant is public (DirectoryListing#public_facilities). Fields stored on the company
# record (description, website, headquarters...) show only when the record
# has evidence of its own.
#
# Sources are numbered once, in reading order (description, key facts, deals,
# then plants), so chips and the source list agree.
class CompanyProfile
  # Lists longer than this collapse behind "Show all" (#90).
  VISIBLE_ITEMS = 6

  attr_reader :organization, :citations

  # nil unless the company exists and is published.
  def self.find(slug)
    organization = Organization.published.find_by(slug:)
    new(organization) if organization
  end

  def initialize(organization)
    @organization = organization
    @citations = CitationIndex.new
    @cited = {}
    number_sources
  end

  delegate :name, :slug, :verified_at, to: :organization

  # The record's own fields, only when a source backs them.
  def sourced? = defined?(@sourced) ? @sourced : (@sourced = organization.evidence.any?)
  %i[description website hq_city hq_state founded_year legal_name].each do |field|
    define_method(field) { organization.public_send(field) if sourced? }
  end

  # [[number, source], ...] for a fact on this page.
  def citations_for(fact) = @cited.fetch(fact) { [] }

  def roles
    @roles ||= sourced_only(organization.organization_roles.published.includes(:role, evidence: :source)).sort_by { |r| r.role.name }
  end

  # Roles to show: a general role is left out when a more specific one under
  # it is there too ("Molten salt coolant", not "Coolant, Molten salt coolant").
  def shown_roles
    parent_ids = roles.map { |r| r.role.parent_id }.compact
    roles.reject { |r| parent_ids.include?(r.role_id) }
  end

  def technologies
    @technologies ||= sourced_only(organization.organization_technologies.published.includes(:technology, evidence: :source)).sort_by { |t| t.technology.name }
  end

  # Deals in both directions, with the other company published (the scope
  # needs both ends published), except "subsidiary of", which the key facts
  # show as the parent company.
  def deals
    @deals ||= Relationship.published
      .where(from_organization: organization).or(Relationship.published.where(to_organization: organization))
      .where.not(relationship_type: "subsidiary_of")
      .includes(:from_organization, :to_organization, evidence: :source).to_a
      .select { |deal| deal.evidence.any? }
      .sort_by { |deal| [ -(deal_date(deal)&.jd || 0), deal.relationship_type, other_party(deal).name ] }
  end

  # The short "what" of a deal row (#556): from its stored terms, else the
  # sourced phrase kept on the link, else nothing. Never guessed or cut from a description.
  def deal_line(deal)
    DealLine.for_terms(terms_of(deal), company: organization) || deal.short_phrase
  end

  # When the deal was signed or started: its newest term's date, else the link's own.
  def deal_date(deal)
    terms_of(deal).filter_map { |term| term.signed_on || term.starts_on }.max || deal.started_on
  end

  def parents
    @parents ||= Relationship.published.subsidiary_of.where(from_organization: organization)
      .includes(:to_organization, evidence: :source).select { |link| link.evidence.any? }
  end

  def subsidiaries
    @subsidiaries ||= Relationship.published.subsidiary_of.where(to_organization: organization)
      .includes(:from_organization, evidence: :source).select { |link| link.evidence.any? }
  end

  def plant_links
    @plant_links ||= begin
      organization.facility_relationships.published
        .where(facility_id: DirectoryListing.new.public_facilities.select(:id))
        .includes({ facility: [ { evidence: :source }, { parent: { evidence: :source } } ] }, evidence: :source).to_a
        .select { |link| link.evidence.any? }
        .sort_by { |link| [ link.relationship_type, link.facility.name ] }
    end
  end

  # A plant's own type, status and place show beside a link only when the
  # plant is verified and has a source, which is then cited too.
  def plant_facts?(facility) = facility.verified? && facility.evidence.any?

  # The link's sources plus those of the plant facts shown with it.
  def plant_link_citations(link)
    site = link.facility.parent || link.facility
    [ link, link.facility, site ].uniq.flat_map { |fact| citations_for(fact) }.uniq(&:first)
  end

  # A link's published terms, loaded once for every deal on the page.
  def terms_of(link)
    @terms ||= DealTerm.published.where(link_type: "Relationship", link_id: Relationship.published
      .where(from_organization: organization).or(Relationship.published.where(to_organization: organization)).select(:id)).group_by(&:link_id)
    @terms.fetch(link.id, [])
  end

  def other_party(deal) = deal.from_organization_id == organization.id ? deal.to_organization : deal.from_organization

  def aliases
    return [] unless sourced?

    @aliases ||= organization.aliases.map(&:alias).reject { |name| OrganizationAlias.normalize(name) == OrganizationAlias.normalize(organization.name) }
  end

  # Every bucket the company is in (#281), by the same rules as the
  # directory (Bucket), in display order.
  def buckets = @buckets ||= Bucket.for(organization)

  # Its first bucket, where only one label fits: the breadcrumb, its link card.
  def category = buckets.first

  # Fields DESIGN.md marks "must" that this company doesn't have yet.
  def missing_fields
    [ ("One-line description" if description.blank?), ("Headquarters" if hq_city.blank? && hq_state.blank?) ].compact
  end

  # The record's own evidence backs its description and headquarters.
  def description_citations = description.present? ? citations_for(organization) : []

  # The facts the line under the key facts may name (#407): of :headquarters
  # and :legal_name, those shown that one of the record's own quotes states.
  # Checked as the page is drawn, so a value edited since stops being named.
  def quoted_facts
    @quoted_facts ||= begin
      quotes = sourced? ? organization.evidence.map(&:quote).compact : []
      [ (:headquarters if Directory::QuoteBacking.place?(quotes, city: hq_city, state: hq_state)),
        (:legal_name if Directory::QuoteBacking.contains?(quotes, legal_name)) ].compact
    end
  end

  private
    # The company record's own evidence backs its description and the key
    # facts stored on it (website, aliases, legal name, headquarters, founded).
    def number_sources
      cite(organization) if description.present? || website.present? || aliases.any? || legal_name.present?
      shown_roles.each { |role| cite(role) }
      technologies.each { |technology| cite(technology) }
      cite(organization) if hq_city.present? || hq_state.present? || founded_year.present?
      (parents + subsidiaries).each { |link| cite(link) }
      deals.each { |deal| cite(deal) }
      plant_links.each do |link|
        cite(link)
        [ link.facility, link.facility.parent ].compact.each { |facility| cite(facility) if plant_facts?(facility) }
      end
    end

    def sourced_only(records) = records.select { |record| record.evidence.any? }

    def cite(fact)
      @cited[fact] = citations.cite(fact.evidence)
    end
end
