# The connections map on company and plant pages (#363): who owns,
# operates, supplies, sells power to and funds whom, as arrows from giver to
# receiver around the page's own record. Built from the facts the profile
# already shows (published, sourced, current), so the map never says more
# than the page.
#
#   map = ConnectionsMap.for_plant(PlantProfile.find("vogtle"))
#   map.edges.map(&:sentence) # => ["Georgia Power owns Plant Vogtle", ...]
#   map.notes                 # early-stage deals: MOUs, frameworks, prepayments...
#
# Only signed deals become arrows; anything earlier is a Note with its stage
# (DATA.md: the stage is in the description until #264's statuses replace
# it). Unit links fold into one arrow per company and site. More than six
# plants fold into one node (#folded), which opens in place (#opened).
class ConnectionsMap
  FOLD_OVER = 6

  # The five verbs, in the order the text version lists them.
  VERBS = [ "owns", "operates", "supplies", "sells power to", "funds" ].freeze

  # How a description that isn't a signed deal starts (PM and Data Quality, 17 Oct).
  NOT_SIGNED = [ "MOU", "Framework", "Term sheet", "Binding term sheet", "Letter of intent", "Non-binding", "Preorder",
    "Option", "Conditional", "Announced plan", "Agreement to explore", "Partnership", "Strategic agreement", "Prepayment" ].freeze

  # Legal endings dropped for a short name where a full one doesn't fit.
  LEGAL_ENDINGS = /(?:,?\s+(?:Inc\.?|LLC|L\.L\.C\.|Corporation|Corp\.?|Company|Co\.?|Holdings|Ltd\.?|L\.P\.|LP|plc))+\z/i

  # record: the Organization or Facility; members: the plants a fold holds.
  Node = Data.define(:key, :name, :short_name, :kind, :record, :members) do
    def plant? = kind == :plant
    def fold? = kind == :fold
    def company? = kind == :company
  end

  # facts: the links behind it (several when units fold into their site);
  # details: what the card says under the verb; sources: unique, in order.
  # covers: on an arrow to folded plants, how many of them it's about.
  Edge = Data.define(:id, :giver, :receiver, :verb, :facts, :details, :sources, :checked_on, :covers) do
    def initialize(covers: nil, **fields) = super

    # "Constellation owns 2 of 13 plants" when an arrow to a fold covers only some.
    def sentence
      fold = [ giver, receiver ].find(&:fold?)
      return "#{giver.name} #{verb} #{receiver.name}" unless fold && covers && covers < fold.members.size

      part = "#{covers} of #{fold.name}"
      giver.fold? ? "#{part} #{verb} #{receiver.name}" : "#{giver.name} #{verb} #{part}"
    end
  end

  # stage: "Framework · Oct 2024", or nil when the description names none.
  # other: the company or plant the deal is with, named first, since the
  # description often doesn't name it ("Conditional HALEU allocation").
  Note = Data.define(:id, :text, :stage, :sources, :fact, :other)

  attr_reader :centre, :edges, :notes
  # Each company's bucket by id, when they're known already (the /design example).
  attr_writer :categories

  def self.for_company(profile) = new(profile.organization).tap { |map| map.send(:build_company, profile) }
  def self.for_plant(profile) = new(profile.site).tap { |map| map.send(:build_plant, profile) }

  # What a plant's name ends with that a short name can drop.
  PLANT_ENDINGS = /\s+(?:Nuclear Power Plant|Nuclear Power Station|Nuclear Generating Station|Nuclear Generating Plant|Generating Station|Clean Energy Center|Nuclear Plant|Nuclear Station|Power Plant|Power Station|Energy Center)\z/i

  # "Oglethorpe Power Corporation" → "Oglethorpe Power", "Calvert Cliffs
  # Nuclear Power Plant" → "Calvert Cliffs"; nil when nothing shorter. A
  # stored short name (DQ's, when the field exists) wins.
  def self.short_name(name, plant: false)
    short = name.to_s.sub(plant ? PLANT_ENDINGS : LEGAL_ENDINGS, "").strip
    short if short.present? && short != name
  end

  # A deal is an arrow once signed: a power deal only when its description
  # says "Signed"; any other deal unless it starts with an earlier stage or
  # is pending.
  # plant: a plant link, which only its words can make early-stage.
  def self.signed?(deal, plant: false)
    text = deal.description.to_s.strip
    return text.match?(/\ASigned\b/i) if !plant && deal.relationship_type == "offtake_with"

    NOT_SIGNED.none? { |label| text.match?(/\A#{Regexp.escape(label)}\b/i) } && !text.match?(/\bpending\b/i)
  end

  def initialize(record)
    @centre = node_for(record)
    @nodes = { @centre.key => @centre }
    @edges = []
    @notes = []
  end

  def empty? = edges.empty?

  def nodes = edges.flat_map { |edge| [ edge.giver, edge.receiver ] }.uniq(&:key)
  def others = nodes.reject { |node| node.key == centre.key }

  # "4 companies · 13 plants": who the map links to, the page's own record left out.
  def companies = others.count(&:company?)
  def plants = others.count(&:plant?)

  # Whether a view folds plants: more than six of them by one verb.
  def folds? = plant_edges.group_by(&:verb).any? { |_, edges| edges.size > FOLD_OVER }

  # The map as first drawn: plants folded into one node when there are many.
  def folded
    return edges unless folds?

    plants = others.select(&:plant?)
    fold = Node.new(key: "fold-plants", name: "#{plants.size} plants", short_name: nil, kind: :fold, record: nil, members: plants)
    others_edges = edges - plant_edges
    merged = plant_edges.group_by { |edge| [ edge.verb, edge.giver.plant? ] }.map do |(verb, from_plant), group|
      names = group.map { |edge| (from_plant ? edge.giver : edge.receiver).name }
      Edge.new(id: "fold-#{verb.parameterize}", giver: from_plant ? fold : centre, receiver: from_plant ? centre : fold, verb:,
        facts: group.flat_map(&:facts), details: [ names.size < plants.size ? "#{names.size} of #{plants.size}: #{names.join(', ')}" : names.join(", ") ],
        sources: group.flat_map(&:sources).uniq, checked_on: group.filter_map(&:checked_on).max, covers: names.size)
    end
    others_edges + merged
  end

  def opened = edges

  # An arrow from records already in hand (the /design example); profiles build their own.
  def link(giver, receiver, verb, facts, lead: nil) = add(giver, receiver, verb, facts, lead:)

  # A company's first bucket (#281), for its node's colour and icon; one
  # query per bucket for the whole map.
  def category(node)
    return unless node.company?

    @categories ||= begin
      ids = nodes.select(&:company?).map { |company| company.record.id }
      finder = Bucket.new
      Category.buckets.each_with_object({}) do |category, found|
        Organization.where(id: ids).where(id: finder.ids(category)).pluck(:id).each { |id| found[id] ||= category }
      end
    end
    @categories[node.record.id]
  end

  private
    # Arrows to neighbouring plants: on a plant page the centre is a plant too, and doesn't count.
    def plant_edges = edges.select { |edge| [ edge.giver, edge.receiver ].any? { |node| node.plant? && node.key != centre.key } }

    def build_company(profile)
      current(profile.parents).each { |link| add(link.to_organization, centre.record, "owns", [ link ]) }
      current(profile.subsidiaries).each { |link| add(centre.record, link.from_organization, "owns", [ link ]) }
      current(profile.deals).each do |deal|
        next note(deal) unless self.class.signed?(deal)

        case deal.relationship_type
        when "supplies" then add(deal.from_organization, deal.to_organization, "supplies", [ deal ])
        when "invests_in", "funds" then add(deal.from_organization, deal.to_organization, "funds", [ deal ])
        when "offtake_with" then add(deal.to_organization, deal.from_organization, "sells power to", [ deal ])
        end
      end
      current(profile.plant_links).group_by { |link| [ link.facility.parent || link.facility, link.relationship_type ] }
        .each { |(site, type), links| add_plant_link(centre.record, site, type, links) }
    end

    def build_plant(profile)
      current(profile.links).group_by { |link| [ link.organization, link.relationship_type ] }
        .each { |(company, type), links| add_plant_link(company, centre.record, type, links) }
    end

    def current(links) = links.reject { |link| link.ended_on && link.ended_on <= Date.current }

    def add_plant_link(company, site, type, links)
      case type
      when "owns", "operates" then add(company, site, type, links)
      when "vendor_for" then add(company, site, "supplies", links, lead: "Reactor design")
      when "offtakes_from"
        # A plant power deal is an arrow unless its words say it isn't signed yet.
        signed, early = links.partition { |link| self.class.signed?(link, plant: true) }
        early.each { |link| note(link) }
        add(site, company, "sells power to", signed) if signed.any?
      end
    end

    def add(giver, receiver, verb, facts, lead: nil)
      sources = facts.flat_map { |fact| fact.evidence.map(&:source) }.compact.uniq.select { |source| Source.web_address?(source.url) }
      return if sources.empty? # every arrow names its source

      @edges << Edge.new(id: "#{facts.first.class.name.underscore.dasherize}-#{facts.first.id}", giver: node_for(giver), receiver: node_for(receiver),
        verb:, facts:, details: [ lead, *details(facts) ].compact, sources:, checked_on: facts.filter_map(&:verified_at).max&.to_date)
    end

    def details(facts)
      units = facts.map(&:facility).select { |facility| facility.parent_id } if facts.first.is_a?(FacilityRelationship)
      [ *facts.map { |fact| fact.description.presence }.compact.uniq,
        (units.map(&:name).join(", ") if units.present?),
        *facts.filter_map { |fact| share(fact) },
        dates(facts.first) ].compact
    end

    def share(fact) = ("#{fact.ownership_pct.to_f.round(1).to_s.delete_suffix('.0')}% share" if fact.try(:ownership_pct))

    def dates(fact)
      return unless fact.started_on

      "#{fact.started_on <= Date.current ? "Since" : "From"} #{fact.started_on.strftime('%b %Y')}"
    end

    # An early-stage deal: its stage tag and the rest of the description.
    def note(deal)
      sources = deal.evidence.map(&:source).compact.uniq.select { |source| Source.web_address?(source.url) }
      text = deal.description.to_s.strip
      return if sources.empty? || text.empty?

      stage = nil
      if (match = text.match(/\A([^:(]{2,60}?)\s*(?:\(([^)]*)\))?:\s*(.+)\z/m))
        stage = [ match[1].strip, match[2].presence ].compact.join(" · ")
        text = match[3].strip.upcase_first
      end
      @notes << Note.new(id: "note-#{deal.class.name.underscore.dasherize}-#{deal.id}", text:, stage:, sources:, fact: deal, other: other_party(deal))
    end

    def other_party(deal)
      if deal.is_a?(FacilityRelationship)
        centre.plant? ? deal.organization : (deal.facility.parent || deal.facility)
      else
        deal.from_organization_id == centre.record.id ? deal.to_organization : deal.from_organization
      end
    end

    def node_for(record)
      key = record.is_a?(Facility) ? "facility-#{record.id}" : "organization-#{record.id}"
      @nodes ||= {}
      @nodes[key] ||= if record.is_a?(Facility)
        Node.new(key:, name: record.name, short_name: record.try(:short_name).presence || self.class.short_name(record.name, plant: true),
          kind: :plant, record:, members: [])
      else
        Node.new(key:, name: record.name, short_name: record.try(:short_name).presence || self.class.short_name(record.name),
          kind: :company, record:, members: [])
      end
    end
end
