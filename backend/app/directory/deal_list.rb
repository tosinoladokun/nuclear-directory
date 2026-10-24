# Every published power deal, one row per agreement (#256), for the first
# data piece (#255, "Every US hyperscaler nuclear power deal, sourced") and
# the open dataset (#254). Read from deal terms, not descriptions: who buys
# from whom, which plant, MW, money, dates, the form of agreement and its
# status, whether it's in the headline count, and the sources that state it.
#
#   Directory::DealList.offtakes # => [Row, …], newest signed first
module Directory::DealList
  # buyer and seller are OrganizationRefs; plant is a FacilityRef (a plant
  # offtake); sources are Source values. Plain values only, never models,
  # as everything the directory hands out (README).
  # counted: a signed power deal with no open condition (DealTerm#counted?);
  # the rest are listed by stage, or as "signed, pending" with their conditions.
  Row = Data.define(:term_id, :key, :buyer, :seller, :plant, :capacity_mw, :firm_mw, :amount_usd, :signed_on, :starts_on, :ends_on,
    :term_years, :agreement, :status, :conditions, :counted, :sources)

  POWER_LINKS = %w[offtake_with offtakes_from].freeze

  Source = Data.define(:url, :title, :published_on)

  def self.offtakes
    terms = DealTerm.published.where(term_type: "offtake").includes(:link, evidence: :source).to_a
    ActiveRecord::Associations::Preloader.new(records: terms.map(&:link).grep(Relationship), associations: %i[from_organization to_organization]).call
    ActiveRecord::Associations::Preloader.new(records: terms.map(&:link).grep(FacilityRelationship), associations: %i[organization facility]).call
    # Power deals only: a supply contract under "supplies" points from
    # supplier to customer and isn't one.
    terms = terms.select { |term| POWER_LINKS.include?(term.link&.relationship_type) }
    terms.map { |term| row(term) }.sort_by { |row| [ row.signed_on ? 0 : 1, -(row.signed_on || row.starts_on || Date.new(1900)).jd, row.key.to_s ] }
  end

  def self.row(term)
    link = term.link
    buyer, seller, plant =
      case link
      when Relationship then [ link.from_organization, link.to_organization, nil ]
      when FacilityRelationship then [ link.organization, nil, link.facility ]
      end
    org = ->(record) { record && Directory::OrganizationRef.from(record) }
    Row.new(term_id: term.id, key: term.external_id, buyer: org.(buyer), seller: org.(seller), plant: plant && Directory::FacilityRef.from(plant), capacity_mw: term.capacity_mw, firm_mw: term.firm_mw,
      amount_usd: term.amount_usd, signed_on: term.signed_on, starts_on: term.starts_on, ends_on: term.ends_on, term_years: term.term_years,
      agreement: term.agreement, status: term.status, conditions: term.conditions, counted: term.counted?,
      sources: term.evidence.map(&:source).uniq.map { |source| Source.new(url: source.url, title: source.title, published_on: source.published_on) })
  end
  private_class_method :row
end
