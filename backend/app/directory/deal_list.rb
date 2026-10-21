# Every published power deal, one row per agreement (#256), for the first
# data piece (#255, "Every US hyperscaler nuclear power deal, sourced") and
# the open dataset (#254). Read from deal terms, not descriptions: who buys
# from whom, which plant, MW, money, dates, the form of agreement and its
# status, whether it's in the headline count, and the sources that state it.
#
#   Directory::DealList.offtakes # => [Row, …], newest signed first
module Directory::DealList
  # buyer and seller are organizations; plant is a facility (a plant offtake).
  # counted: a signed power deal with no open condition (DealTerm#counted?);
  # the rest are listed by stage, or as "signed, pending" with their conditions.
  Row = Data.define(:term_id, :key, :buyer, :seller, :plant, :capacity_mw, :firm_mw, :amount_usd, :signed_on, :starts_on, :ends_on,
    :term_years, :agreement, :status, :conditions, :counted, :sources)

  def self.offtakes
    terms = DealTerm.published.where(term_type: "offtake").includes(:link, evidence: :source).to_a
    ActiveRecord::Associations::Preloader.new(records: terms.map(&:link).grep(Relationship), associations: %i[from_organization to_organization]).call
    ActiveRecord::Associations::Preloader.new(records: terms.map(&:link).grep(FacilityRelationship), associations: %i[organization facility]).call
    terms.map { |term| row(term) }.sort_by { |row| [ row.signed_on ? 0 : 1, -(row.signed_on || row.starts_on || Date.new(1900)).jd, row.key.to_s ] }
  end

  def self.row(term)
    link = term.link
    buyer, seller, plant =
      case link
      when Relationship then [ link.from_organization, link.to_organization, nil ]
      when FacilityRelationship then [ link.organization, nil, link.facility ]
      end
    Row.new(term_id: term.id, key: term.external_id, buyer:, seller:, plant:, capacity_mw: term.capacity_mw, firm_mw: term.firm_mw,
      amount_usd: term.amount_usd, signed_on: term.signed_on, starts_on: term.starts_on, ends_on: term.ends_on, term_years: term.term_years,
      agreement: term.agreement, status: term.status, conditions: term.conditions, counted: term.counted?,
      sources: term.evidence.map(&:source).uniq)
  end
  private_class_method :row
end
