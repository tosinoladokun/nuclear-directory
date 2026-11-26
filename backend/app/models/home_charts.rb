# The charts on homepage B (#909): one large and two small cards per visit, each a plain question answered by a chart.
# The questions are a pool (config/home_charts.yml), each one checked by Data Quality against an authority (EIA-860M)
# before it joins; the answers come from published facts only, counted the way Data Quality checked them.
#
#   HomeCharts.cards_for(request) # => [[question, data], ...] large first, or nil
#   HomeCharts.data(:state_power) # => { rows: [{ label: "Illinois", value: 11.6 }, ...] }
#
# A chart whose facts aren't complete (a unit with no capacity, a plant with no coordinates) has nothing to show: its
# card sits out rather than answer from part of the data (Tosin, 25 Nov: no guesswork).
#
# Which cards: every set of one large and two small cards the pool allows (no card twice, never two cards that are
# not_with each other) is listed in a fixed order; a visitor's set is picked from a hash of their IP address and browser
# plus the day number, so it changes every day, and the next day's set is never the same one. The hash only picks the
# set: it's never stored or sent.
class HomeCharts
  Question = Data.define(:key, :question, :short, :chart, :sizes, :axes, :tick, :decimals, :not_with) do
    def self.from(entry)
      entry = entry.symbolize_keys
      new(key: entry.fetch(:key).to_sym, question: entry.fetch(:question), short: entry[:short] || entry[:question],
        chart: entry.fetch(:chart).to_sym, sizes: entry.fetch(:sizes).map(&:to_sym), axes: (entry[:axes] || {}).symbolize_keys,
        tick: entry[:tick], decimals: entry[:decimals] || 0, not_with: Array(entry[:not_with]).map(&:to_sym))
    end

    def large? = sizes.include?(:large)
    def small? = sizes.include?(:small)
  end

  CHARTS = %i[map bars columns split].freeze
  POOL = YAML.load_file(Rails.root.join("config/home_charts.yml")).map { |entry| Question.from(entry) }.freeze
  TOP = 8
  # Map dots closer than this (in HomeMap's 600 by 370 box) are drawn as one.
  SAME_SPOT = 1.0

  # Reactor sizes as Data Quality counted them (MW, net summer): under 600, then 600 to 899, and so on.
  SIZE_BANDS = [ [ 0, 600, "<600" ], [ 600, 900, "600–899" ], [ 900, 1100, "900–1,099" ], [ 1100, 1300, "1,100–1,299" ], [ 1300, nil, "1,300+" ] ].freeze
  REACTOR_TYPES = { "PWR" => "Pressurized water (PWR)", "BWR" => "Boiling water (BWR)" }.freeze
  # The NRC's words for a power reactor's status (Data Quality, #909): never "closed" for one being decommissioned.
  REACTOR_STATUSES = { "operating" => "Operating", "decommissioning" => "Decommissioning", "not_operating" => "Not operating" }.freeze

  # Every allowed set from these questions, [large, small, small], in a fixed order.
  def self.sets(pool = POOL)
    pool.select(&:large?).flat_map do |large|
      pool.select { |question| question != large && question.small? }.combination(2).map { |pair| [ large, *pair ] }
    end.reject { |set| set.any? { |question| set.any? { |other| question.not_with.include?(other.key) } } }
  end

  # The visitor's cards with each chart's data, [[question, data], ...] large first; nil when no set can be shown.
  # data: how a chart's data is read (tests pass their own). picked: keys of a set to show instead, for a forced visit;
  # used only when it's one of the allowed sets with every chart shown.
  def self.cards_for(request, day: Date.current, data: method(:data), pool: POOL, picked: nil)
    values = Hash.new { |hash, key| hash[key] = data.call(key) }
    sets = sets(pool.select { |question| shown?(question, values[question.key]) })
    return if sets.empty?

    # The large card first; the small ones in either order.
    keys = ->(set) { set.map { |question| question.key.to_s } }
    set = sets.find { |candidate| keys[candidate].first == picked.first && keys[candidate].drop(1).sort == picked.drop(1).sort } if picked.present?
    (set || sets[index(request, day, sets.size)]).map { |question| [ question, values[question.key] ] }
  end

  # Today's place in the list of n sets: the visitor's hash plus the day number times a step that has no factor in
  # common with n, so consecutive days never land on the same set and the large card usually changes too.
  def self.index(request, day, n)
    digest = OpenSSL::HMAC.digest("SHA256", Rails.application.key_generator.generate_key("home-charts", 32),
      [ request.remote_ip, request.user_agent.to_s ].join("\n"))
    (digest.unpack1("N") + day.jd * step(n)) % n
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { feature: "home_charts" })
    0
  end

  def self.step(n)
    return 1 if n < 3

    (n * 0.382).ceil.step.find { |step| step.gcd(n) == 1 }
  end

  def self.shown?(question, value)
    case [ question.chart, value ]
    in [ :map, { dots: [ _, * ] } ] then true
    in [ :bars, { rows: [ _, * ] } ] then true
    in [ :columns, { columns: [ _, * ] => columns } ] then columns.sum { |column| column[:value] }.positive?
    in [ :split, { parts: [ _, _, * ] } ] then true
    else false
    end
  end

  def self.find(key) = POOL.find { |question| question.key == key.to_sym }

  # A chart's data, plain values only so the cache can hold it.
  def self.data(key)
    question = find(key) or raise ArgumentError, "no home chart #{key}"
    Rails.cache.fetch([ "home-charts/v4", question.key, DataVersion.current ]) { new.public_send(question.key) }
  end

  # 1. Where are the operating US nuclear plants: each site with an operating power reactor, at its published
  # coordinates. Every one must have them, or the map would leave plants out. Plants drawn on the same spot (within a
  # pixel, as Hope Creek and Salem are) share one dot and one label (#940). A dot's state is the plant's own; a plant
  # with none shows its name alone. Each plant keeps its slug, for its link (#949). Dots run west to east, the order the
  # arrow keys take.
  def plant_map
    plants = sites.order(:name).pluck(:name, :short_name, :slug, :state, :latitude, :longitude)
    return {} if plants.empty? || plants.any? { |*, lat, lon| lat.nil? || lon.nil? }

    spots = plants.map { |name, short, slug, state, lat, lon| [ HomeMap.point(lon, lat), { name: short.presence || name, slug: }, state.presence && state_name(state) ] }
    groups = spots.each_with_object([]) do |spot, found|
      group = found.find { |(x, y), *| Math.hypot(x - spot[0][0], y - spot[0][1]) <= SAME_SPOT }
      group ? group << spot : found << [ spot[0], spot ]
    end
    { count: plants.size, dots: groups.map { |(x, y), *members| dot(x, y, members) }.sort_by { |dot| [ dot[:x], dot[:y] ] } }
  end

  # 2. Which states have the most nuclear power: operating units' net summer capacity, summed by their site's state.
  def state_power
    rows = unit_rows(:capacity_mw, "sites.state")
    return {} if incomplete?(rows)

    { rows: top(rows.group_by(&:last).map { |state, units| { label: state_name(state), value: gw(units.sum(&:first)) } }) }
  end

  # 3. Which are the largest US nuclear plants: operating units' net summer capacity, summed by site. Each row is a
  # plant, so it links to the plant's page (#949).
  def largest_plants
    rows = unit_rows(:capacity_mw, "sites.id")
    return {} if incomplete?(rows)

    names = sites.pluck(:id, :name, :short_name, :slug).to_h { |id, *rest| [ id, rest ] }
    { rows: top(rows.group_by(&:last).map { |id, units| name, short, slug = names.fetch(id); { label: short.presence || name, title: name, plant: slug, value: gw(units.sum(&:first)) } }) }
  end

  # 4. How big are US reactors: operating units counted in Data Quality's size bands.
  def reactor_sizes
    sizes = units.pluck(:capacity_mw)
    return {} if sizes.empty? || sizes.any?(&:nil?)

    { columns: SIZE_BANDS.map { |from, to, label| { label:, value: sizes.count { |mw| mw >= from && (to.nil? || mw < to) } } },
      edges: SIZE_BANDS.drop(1).map { |from, *| from.to_fs(:delimited) } }
  end

  # 5. How many reactors does each plant have: sites counted by their number of operating units, 1 to 4 (or more, if a
  # plant ever has more).
  def reactors_per_plant
    tally = units.group(:parent_id).count.values.tally
    return {} if tally.empty?

    { columns: (1..[ 4, tally.keys.max ].max).map { |n| { label: n.to_s, value: tally.fetch(n, 0) } } }
  end

  # 6. What kind of reactors does the US run: operating units by reactor type.
  def reactor_types
    types = units.group(:reactor_type).count
    return {} if types.empty? || types.key?(nil)

    { parts: types.sort_by { |type, n| [ -n, type ] }.map { |type, n| { label: REACTOR_TYPES.fetch(type, type), value: n } } }
  end

  # 7. Which states have the most reactors: operating units counted by their site's state.
  def state_reactors
    rows = unit_rows("1", "sites.state")
    return {} if incomplete?(rows)

    { rows: top(rows.group_by(&:last).map { |state, units| { label: state_name(state), value: units.size } }) }
  end

  # 8. Whose reactor designs does the US run: operating units counted by the company whose design they are (a verified
  # vendor_for link; a unit without its own link takes its site's, as Vogtle 3 and 4 do). The company that holds the
  # design today, so the question is in the present tense. Each unit must have exactly one (Tosin approved
  # the wording, 25 Nov).
  def reactor_vendors
    links = FacilityRelationship.published.vendor_for.where(organization_id: Organization.published.select(:id))
    by_facility = links.pluck(:facility_id, :organization_id).group_by(&:first).transform_values { |rows| rows.map(&:last).uniq }
    vendors = units.pluck(:id, :parent_id).map { |id, site| by_facility[id] || by_facility[site] || [] }
    return {} if vendors.empty? || vendors.any? { |orgs| orgs.size != 1 }

    orgs = Organization.where(id: vendors.flatten.uniq).index_by(&:id)
    { rows: top(vendors.flatten.tally.map { |id, n| { label: orgs[id].short_name.presence || orgs[id].name, title: orgs[id].name, company: orgs[id].slug, value: n } }) }
  end

  # 9. How many US power reactors still run: power reactors by status, as the NRC words it. A reactor is a unit, or a
  # site that is itself the one reactor (it has no units under it). Under construction and planned stay out.
  def reactor_status
    reactors = Facility.published.where(facility_type: "power_reactor", status: REACTOR_STATUSES.keys)
    reactors = reactors.where.not(parent_id: nil).or(reactors.where(parent_id: nil).where.not(id: Facility.published.where.not(parent_id: nil).select(:parent_id)))
    counts = reactors.group(:status).count
    return {} unless counts["operating"].to_i.positive?

    { parts: counts.sort_by { |status, n| [ -n, status ] }.map { |status, n| { label: REACTOR_STATUSES.fetch(status), value: n } } }
  end

  private
    # Operating power-reactor units the public sees (Facility.published: verified, under a site that's public).
    def units = Facility.published.where(facility_type: "power_reactor", status: "operating").where.not(parent_id: nil)

    def sites = Facility.where(id: units.select(:parent_id))

    # [[value, site column], ...] for each operating unit.
    def unit_rows(value, column)
      units.joins("INNER JOIN facilities sites ON sites.id = facilities.parent_id")
        .pluck(Arel.sql(value.is_a?(Symbol) ? "facilities.#{value}" : value), Arel.sql(column))
    end

    # One dot for the plants on one spot: Hope Creek and Salem, in New Jersey.
    def dot(x, y, members)
      states = members.map(&:last)
      { plants: members.map { |_, plant, _| plant }.sort_by { |plant| plant[:name] },
        state: (states.uniq.to_sentence(two_words_connector: " and ", last_word_connector: " and ") if states.all?), x:, y: }
    end

    def incomplete?(rows) = rows.empty? || rows.flatten.any?(&:blank?)

    def top(rows) = rows.sort_by { |row| [ -row[:value], row[:label] ] }.first(TOP)

    def gw(mw) = (mw.to_d / 1000).to_f

    def state_name(code) = LinkCard::US_STATES.fetch(code, code)
end
