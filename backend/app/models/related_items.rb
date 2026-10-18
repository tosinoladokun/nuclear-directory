# What a company's or plant's Record lists under its public card (#201,
# Design's spec on #166): a plant's units and company links; a company's
# deals and links, then its plants and sites. Every row, whatever its
# status, with that status and the claims waiting on it.
#
#   related = RelatedItems.new(Facility.find(12))
#   related.sections        # => [Section(key: "units", …), Section(key: "companies", …)]
#   related.section("units").rows.first.status  # => "Live"
class RelatedItems
  # rows: every row; the page shows removed and rejected ones on request.
  Section = Data.define(:key, :title, :rows) do
    def shown(removed) = removed ? rows : rows.reject(&:removed?)
    def removed_count = rows.count(&:removed?)
  end

  # item: [type, id] of the row's own fact (a unit or a link): its status,
  # waiting claims and actions are about it. target: [type, id] of what its
  # name opens (a company's or plant's Record, or a unit's fact page).
  # words: the link's words or a unit's reactor type; details: muted extras.
  Row = Data.define(:item, :target, :name, :words, :details, :status, :waiting, :first_claim) do
    def removed? = %w[Removed Rejected].include?(status)
    def anchor = "item-#{item.join('-')}"
    # Edit approves, so a removed or rejected row isn't edited (Put back first).
    def editable? = %w[Live Hidden Waiting].include?(status)
    def live? = %w[Live Hidden].include?(status)
  end

  STATUS_OF = { "verified" => "Live", "pending" => "Waiting", "unpublished" => "Removed", "rejected" => "Rejected" }.freeze
  # Links read in this order on the page, then by share (high first).
  LINK_ORDER = %w[owns operates vendor_for offtakes_from].freeze
  DEAL_KINDS = { "supplies" => "Supply", "invests_in" => "Investment", "funds" => "Funding", "offtake_with" => "Power deal", "subsidiary_of" => "Subsidiary" }.freeze

  attr_reader :record

  def initialize(record)
    @record = record
  end

  def sections
    @sections ||= (record.is_a?(Organization) ? company_sections : plant_sections).reject { |section| section.rows.empty? }
  end

  def section(key) = sections.find { |section| section.key == key }

  # Where a row sits among its section's siblings as the Record showed them
  # (removed ones only when it showed them), for Previous and Next on the
  # page it opens. A row taken off since counts the removed ones in, so it
  # keeps its place; removed: says which set was used.
  def neighbours(key, item, removed: false)
    section = section(key) or return
    removed ||= section.rows.find { |row| row.item == item }&.removed? || false
    rows = section.shown(removed)
    index = rows.index { |row| row.item == item } or return
    { index: index + 1, total: rows.size, previous: (rows[index - 1] if index.positive?), next: rows[index + 1], removed: }
  end

  private
    def plant_sections
      units = Facility.where(parent_id: record.id).to_a
      links = FacilityRelationship.where(facility_id: [ record.id, *units.map(&:id) ]).includes(:organization, :facility).to_a
      [
        Section.new("units", "Units", rows_for(units.sort_by { |unit| unit.name.to_s }) do |unit|
          capacity = "#{ActiveSupport::NumberHelper.number_to_delimited(unit.capacity_mw.to_f.round(1).to_s.delete_suffix('.0'))} MW" if unit.capacity_mw
          { target: [ "Facility", unit.id ], name: unit.name, words: unit.reactor_type, details: [ capacity ].compact }
        end),
        Section.new("companies", "Companies", rows_for(sort_links(links)) do |link|
          { target: [ "Organization", link.organization_id ], name: link.organization.name, words: facility_verb(link),
            details: [ share(link), (link.facility.name unless link.facility_id == record.id), *dates(link) ].compact }
        end)
      ]
    end

    def company_sections
      deals = Relationship.where(from_organization_id: record.id).or(Relationship.where(to_organization_id: record.id))
        .includes(:from_organization, :to_organization).to_a
      links = FacilityRelationship.where(organization_id: record.id).includes(:organization, facility: :parent).to_a
      [
        Section.new("deals", "Deals and links", rows_for(deals.sort_by { |deal| [ DEAL_KINDS.keys.index(deal.relationship_type), other(deal).name.to_s ] }) do |deal|
          { target: [ "Organization", other(deal).id ], name: other(deal).name, words: deal_words(deal),
            details: [ DEAL_KINDS[deal.relationship_type], deal.description.presence, *dates(deal) ].compact }
        end),
        Section.new("plants", "Plants and sites", rows_for(sort_links(links)) do |link|
          site = link.facility.parent || link.facility
          { target: [ "Facility", site.id ], name: site.name, words: facility_verb(link),
            details: [ DirectoryHelper::FACILITY_TYPE_LABELS[site.facility_type.to_s], DirectoryHelper::FACILITY_STATUS_LABELS[site.status.to_s],
              site.state.presence, (link.facility.name unless link.facility == site), share(link), *dates(link) ].compact }
        end)
      ]
    end

    # One row per fact, with its status and waiting claims worked out per model in one query each.
    def rows_for(facts)
      return [] if facts.empty?

      model = facts.first.class
      published = model.published.where(id: facts.map(&:id)).pluck(:id).to_set
      # Counted as the fact page counts them, so its first claim has a decision bar.
      waiting = DataQuality::Review.waiting_counts(type: model.name, ids: facts.map(&:id))
      facts.map do |fact|
        count, first = waiting.fetch(fact.id, [ 0, nil ])
        status = fact.verification_status == "verified" && !published.include?(fact.id) ? "Hidden" : STATUS_OF.fetch(fact.verification_status)
        Row.new(item: [ model.name, fact.id ], status:, waiting: count, first_claim: first, **yield(fact))
      end
    end

    def sort_links(links) = links.sort_by { |link| [ LINK_ORDER.index(link.relationship_type) || 99, -(link.ownership_pct || -1), link.organization.name.to_s, link.facility.name.to_s ] }

    def facility_verb(link) = DirectoryHelper::FACILITY_RELATIONSHIP_VERBS.fetch(link.relationship_type, link.relationship_type.humanize(capitalize: false))

    def other(deal) = deal.from_organization_id == record.id ? deal.to_organization : deal.from_organization

    # Read as on the public page: "offtakes from Talen Energy" when the other
    # company is the subject; the whole sentence when this one is.
    def deal_words(deal)
      verb = DirectoryHelper::RELATIONSHIP_VERBS.fetch(deal.relationship_type, deal.relationship_type.humanize(capitalize: false))
      deal.from_organization_id == record.id ? "#{record.name} #{verb} #{deal.to_organization.name}" : "#{verb} #{record.name}"
    end

    def share(link) = ("#{link.ownership_pct.to_f.round(1).to_s.delete_suffix('.0')}%" if link.ownership_pct)

    def dates(fact)
      [ ("since #{fact.started_on.strftime('%b %Y')}" if fact.started_on && fact.started_on <= Date.current),
        ("from #{fact.started_on.strftime('%b %Y')}" if fact.started_on && fact.started_on > Date.current),
        ("ended #{fact.ended_on.strftime('%b %Y')}" if fact.ended_on && fact.ended_on <= Date.current),
        ("through #{fact.ended_on.strftime('%b %Y')}" if fact.ended_on && fact.ended_on > Date.current) ].compact
    end
end
