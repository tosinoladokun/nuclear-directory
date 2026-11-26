require "test_helper"
require_relative "../support/directory_builders"

# Homepage B's charts (#909): a pool of questions, each answered from published facts the way Data Quality checked it
# against EIA-860M. Each question's test builds a small directory from rows shaped like EIA's operating generator rows
# and checks the chart against totals worked out from those rows directly, so a query that drifts from the source fails.
class HomeChartsTest < ActiveSupport::TestCase
  include DirectoryBuilders

  Request = Data.define(:remote_ip, :user_agent)

  # [plant, state, latitude, longitude, unit, net summer MW, reactor type], as EIA-860M lists operating generators.
  EIA = [
    [ "Byron", "IL", 42.0742, -89.2817, "Byron 1", 1164.0, "PWR" ],
    [ "Byron", "IL", 42.0742, -89.2817, "Byron 2", 1136.0, "PWR" ],
    [ "Dresden", "IL", 41.3897, -88.2711, "Dresden 2", 894.0, "BWR" ],
    [ "Dresden", "IL", 41.3897, -88.2711, "Dresden 3", 879.0, "BWR" ],
    [ "Plant Vogtle", "GA", 33.1427, -81.7625, "Vogtle 1", 1150.0, "PWR" ],
    [ "Plant Vogtle", "GA", 33.1427, -81.7625, "Vogtle 2", 1152.0, "PWR" ],
    [ "Plant Vogtle", "GA", 33.1427, -81.7625, "Vogtle 3", 1114.0, "PWR" ],
    [ "Plant Vogtle", "GA", 33.1427, -81.7625, "Vogtle 4", 1114.0, "PWR" ],
    [ "Ginna", "NY", 43.2777, -77.3099, "Ginna 1", 560.0, "PWR" ],
    [ "Browns Ferry", "AL", 34.7042, -87.1186, "Browns Ferry 1", 1254.0, "BWR" ],
    [ "Browns Ferry", "AL", 34.7042, -87.1186, "Browns Ferry 2", 1259.0, "BWR" ],
    [ "Browns Ferry", "AL", 34.7042, -87.1186, "Browns Ferry 3", 1309.0, "BWR" ]
  ].freeze

  def charts = HomeCharts.new

  # The rows as the directory holds them: a verified, sourced site per plant and an operating unit per row.
  def build_eia
    EIA.group_by(&:first).to_h do |name, rows|
      _, state, lat, lon = rows.first
      site = cite!(plant(name, state:, latitude: lat, longitude: lon))
      rows.each { |*, unit, mw, type| cite!(plant(unit, parent: site, facility_type: "power_reactor", status: "operating", capacity_mw: mw, reactor_type: type)) }
      [ name, site ]
    end
  end

  def unit(name) = Facility.find_by!(name:)

  test "the pool: every question has a query, a chart kind it can draw and a size, and its not_with names real keys" do
    keys = HomeCharts::POOL.map(&:key)
    assert_equal keys.uniq, keys, "each key once"
    HomeCharts::POOL.each do |question|
      assert_respond_to charts, question.key
      assert_includes HomeCharts::CHARTS, question.chart
      assert File.exist?(Rails.root.join("app/views/home/charts/_#{question.chart}.html.erb")), question.chart
      assert question.sizes.any? && (question.sizes - %i[large small]).empty?, question.key
      assert_operator format(question.short, count: 54).length, :<=, 24, "#{question.key}: the title on a phone fits one line at 320"
      assert format(question.short, count: 54).end_with?("?"), "#{question.key}: the short title is still a question (Design, #935)"
      assert (question.not_with - keys).empty?, question.key
      assert question.axes.values_at(:category, :value).all?(&:present?), "#{question.key}: both axes named" if question.chart == :bars
      assert question.axes.values_at(:x, :y).all?(&:present?), "#{question.key}: both axes named" if question.chart == :columns
      assert question.tick.to_f.positive?, "#{question.key}: a tick step" if question.chart == :bars
    end
  end

  test "1. the map: one dot per site with an operating reactor, at its coordinates" do
    build_eia
    cite!(plant("Shut Site", state: "VT", latitude: 42.78, longitude: -72.51)).tap do |site|
      cite!(plant("Shut 1", parent: site, facility_type: "power_reactor", status: "shut_down"))
    end

    data = charts.plant_map
    byron = data[:dots].find { |dot| dot[:plants].map { |plant| plant[:name] } == [ "Byron" ] }
    assert_equal EIA.map(&:first).uniq.size, data[:count]
    assert_equal EIA.map(&:first).uniq.sort, data[:dots].flat_map { |dot| dot[:plants].map { |plant| plant[:name] } }.sort
    assert_equal HomeMap.point(-89.2817, 42.0742), byron.values_at(:x, :y)
    assert_equal "Illinois", byron[:state], "the full state name, from the plant's record (#940)"
    assert_equal Facility.find_by(name: "Byron", parent_id: nil).slug, byron[:plants].first[:slug], "the plant's slug, for its link (#949)"
    assert_equal data[:dots].sort_by { |dot| dot[:x] }, data[:dots], "west to east, the arrow keys' order (#949)"
  end

  test "1. plants on the same spot share one dot and one label; a plant's state is never guessed (#940)" do
    build_eia
    # Hope Creek and Salem, 400m apart: the same pixel on the map.
    operating_plant("PSEG Salem Generating Station", state: "NJ", latitude: 39.4625, longitude: -75.5358).update_columns(short_name: "Salem")
    operating_plant("PSEG Hope Creek Generating Station", state: "NJ", latitude: 39.4666, longitude: -75.5377).update_columns(short_name: "Hope Creek")
    operating_plant("No State", state: nil, latitude: 45.0, longitude: -100.0)

    data = charts.plant_map
    assert_equal EIA.map(&:first).uniq.size + 3, data[:count], "the title still counts every plant"
    names = ->(dot) { dot[:plants].map { |plant| plant[:name] } }
    shared = data[:dots].find { |dot| names[dot].include?("Salem") }
    assert_equal [ "Hope Creek", "Salem" ], names[shared], "one dot, each plant with its own link (#949)"
    assert_equal "New Jersey", shared[:state]
    assert_equal 2, shared[:plants].map { |plant| plant[:slug] }.uniq.size
    assert_nil data[:dots].find { |dot| names[dot] == [ "No State" ] }[:state]
  end

  test "1. the map sits out when a plant has no coordinates, rather than leave it off" do
    build_eia.fetch("Ginna").update!(latitude: nil, longitude: nil)
    assert_equal({}, charts.plant_map)
  end

  test "2. nuclear power by state: net summer MW of operating units, summed by state, in GW, largest first" do
    build_eia
    expected = EIA.group_by { |row| row[1] }.transform_values { |rows| rows.sum { |row| row[5] } / 1000 }
    rows = charts.state_power[:rows]
    assert_equal expected.sort_by { |state, gw| -gw }.map(&:first).map { |code| LinkCard::US_STATES[code] }, rows.map { |row| row[:label] }
    rows.each { |row| assert_in_delta expected.fetch(LinkCard::US_STATES.key(row[:label])), row[:value], 0.00001 }
  end

  test "2. a unit with no capacity takes the card out, and so do 3 and 4" do
    build_eia
    unit("Ginna 1").update!(capacity_mw: nil)
    assert_equal({}, charts.state_power)
    assert_equal({}, charts.largest_plants)
    assert_equal({}, charts.reactor_sizes)
  end

  test "3. the largest plants: net summer MW summed per site, short names shown and full names kept" do
    build_eia.fetch("Plant Vogtle").update!(short_name: "Vogtle")
    expected = EIA.group_by(&:first).transform_values { |rows| rows.sum { |row| row[5] } / 1000 }.sort_by { |_, gw| -gw }
    rows = charts.largest_plants[:rows]
    assert_equal expected.map(&:first), rows.map { |row| row[:title] }
    assert_equal "Vogtle", rows.find { |row| row[:title] == "Plant Vogtle" }[:label]
    assert_equal Facility.find_by(name: "Plant Vogtle", parent_id: nil).slug, rows.find { |row| row[:title] == "Plant Vogtle" }[:plant], "each row links to its plant (#949)"
    assert_equal expected.map(&:last), rows.map { |row| row[:value] }
  end

  test "4. reactor sizes: operating units in Data Quality's bands, labelled on the edges between them" do
    build_eia
    bands = [ 0...600, 600...900, 900...1100, 1100...1300, 1300.. ].map { |band| EIA.count { |row| band.cover?(row[5]) } }
    data = charts.reactor_sizes
    assert_equal bands, data[:columns].map { |column| column[:value] }
    assert_equal EIA.size, bands.sum
    assert_equal %w[600 900 1,100 1,300], data[:edges]
  end

  test "5. reactors per plant: plants counted by their number of operating units" do
    build_eia
    expected = EIA.group_by(&:first).values.map(&:size).tally
    data = charts.reactors_per_plant
    assert_equal %w[1 2 3 4], data[:columns].map { |column| column[:label] }
    assert_equal (1..4).map { |n| expected.fetch(n, 0) }, data[:columns].map { |column| column[:value] }
  end

  test "6. reactor types: operating units by type, the largest first; a unit with no type takes the card out" do
    build_eia
    expected = EIA.map(&:last).tally
    assert_equal [ [ "Pressurized water (PWR)", expected["PWR"] ], [ "Boiling water (BWR)", expected["BWR"] ] ],
      charts.reactor_types[:parts].map { |part| part.values_at(:label, :value) }

    unit("Ginna 1").update!(reactor_type: nil)
    assert_equal({}, charts.reactor_types)
  end

  test "7. reactors by state: operating units counted by state; a shut-down or unpublished unit doesn't count" do
    sites = build_eia
    cite!(plant("Byron 3", parent: sites.fetch("Byron"), facility_type: "power_reactor", status: "shut_down", capacity_mw: 1, reactor_type: "PWR"))
    plant("Byron 4", parent: sites.fetch("Byron"), facility_type: "power_reactor", status: "operating", capacity_mw: 1, reactor_type: "PWR", verified: false)

    expected = EIA.map { |row| row[1] }.tally
    assert_equal expected.sort_by { |state, n| [ -n, LinkCard::US_STATES[state] ] }.map { |state, n| [ LinkCard::US_STATES[state], n ] },
      charts.state_reactors[:rows].map { |row| row.values_at(:label, :value) }
  end

  test "8. reactor designs: operating units by their vendor_for company; a unit without its own link takes its site's" do
    sites = build_eia
    westinghouse = cite!(organizations(:westinghouse).tap { |org| org.update_columns(short_name: "Westinghouse", **verification(true)) })
    ge = cite!(company("GE Vernova"))
    %w[Byron\ 1 Byron\ 2 Vogtle\ 1 Vogtle\ 2 Ginna\ 1].each { |name| cite!(link(westinghouse, "vendor_for", unit(name))) }
    cite!(link(westinghouse, "vendor_for", sites.fetch("Plant Vogtle"))) # Vogtle 3 and 4: the site's link
    %w[Dresden\ 2 Dresden\ 3 Browns\ Ferry\ 1 Browns\ Ferry\ 2 Browns\ Ferry\ 3].each { |name| cite!(link(ge, "vendor_for", unit(name))) }

    rows = charts.reactor_vendors[:rows]
    assert_equal [ [ "Westinghouse", 7 ], [ "GE Vernova", 5 ] ], rows.map { |row| row.values_at(:label, :value) }
    assert_equal EIA.size, rows.sum { |row| row[:value] }
    assert_equal "Westinghouse Electric Company", rows.first[:title]
    assert_equal [ westinghouse.slug, ge.slug ], rows.map { |row| row[:company] }, "each row links to its company (#949)"
  end

  test "8. a unit with no design company, from itself or its site, takes the card out" do
    build_eia
    cite!(link(cite!(company("GE Vernova")), "vendor_for", unit("Dresden 2")))
    assert_equal({}, charts.reactor_vendors)
  end

  test "9. power reactors by status, in the NRC's words: a unit, or a site that is itself the one reactor" do
    build_eia
    cite!(plant("Indian Point 2", parent: cite!(plant("Indian Point")), facility_type: "power_reactor", status: "decommissioning"))
    cite!(plant("Kewaunee", facility_type: "power_reactor", status: "decommissioning")) # a site with no units
    cite!(plant("Palisades", facility_type: "power_reactor", status: "not_operating"))
    cite!(plant("Vogtle 5", parent: Facility.find_by!(name: "Plant Vogtle"), facility_type: "power_reactor", status: "planned"))
    Facility.find_by!(name: "Plant Vogtle").update!(facility_type: "power_reactor", status: "operating") # a site with units isn't a reactor itself

    assert_equal [ [ "Operating", EIA.size ], [ "Decommissioning", 2 ], [ "Not operating", 1 ] ],
      charts.reactor_status[:parts].map { |part| part.values_at(:label, :value) }
  end

  test "the sets: one large card and two small ones, no card twice, never two that are not_with each other" do
    sets = HomeCharts.sets
    assert sets.all? { |set| set.first.large? && set.drop(1).all?(&:small?) && set.uniq.size == 3 }
    keys = sets.map { |set| set.map(&:key) }
    assert_not keys.any? { |set| (set & %i[state_power state_reactors]).size == 2 }, "two state rankings never share a screen"
    assert_not keys.any? { |set| (set & %i[reactor_types reactor_status]).size == 2 }, "two split bars never share a screen"
    assert_equal %i[plant_map state_power largest_plants], keys.map(&:first).uniq, "only 1, 2 and 3 take the large slot"
  end

  test "a visitor's set changes every day and stays put within a day" do
    request = Request.new(remote_ip: "203.0.113.9", user_agent: "Safari")
    data = ->(key) { HomeCharts::POOL.find { |question| question.key == key }.then { |question| sample(question.chart) } }
    day = Date.new(2026, 12, 1)
    sets = (0..30).map { |n| HomeCharts.cards_for(request, day: day + n, data:).map { |question, _| question.key } }
    sets.each_cons(2) { |a, b| assert_not_equal a, b }
    assert_operator sets.map(&:first).uniq.size, :>, 1, "the large card changes too"
    assert_equal sets.first, HomeCharts.cards_for(request, day:, data:).map { |question, _| question.key }
  end

  test "a chart with nothing to show sits out of every set; with no set left, nothing" do
    request = Request.new(remote_ip: "203.0.113.9", user_agent: "Safari")
    assert_nil HomeCharts.cards_for(request), "an empty directory has no set"

    data = ->(key) { key == :plant_map ? {} : sample(HomeCharts.find(key).chart) }
    keys = (0..30).flat_map { |n| HomeCharts.cards_for(request, day: Date.new(2026, 12, 1) + n, data:).map { |question, _| question.key } }
    assert_not_includes keys, :plant_map
  end

  test "a forced visit can name its set; a set the pool doesn't allow is ignored" do
    request = Request.new(remote_ip: "203.0.113.9", user_agent: "Safari")
    data = ->(key) { sample(HomeCharts.find(key).chart) }
    assert_equal %i[plant_map reactor_sizes reactor_types],
      HomeCharts.cards_for(request, data:, picked: %w[plant_map reactor_sizes reactor_types]).map { |question, _| question.key }
    assert_equal %i[plant_map reactor_sizes reactor_types],
      HomeCharts.cards_for(request, data:, picked: %w[plant_map reactor_types reactor_sizes]).map { |question, _| question.key }, "small cards in either order"
    assert_not_equal %i[state_power state_reactors reactor_types],
      HomeCharts.cards_for(request, data:, picked: %w[state_power state_reactors reactor_types]).map { |question, _| question.key }
  end

  test "HomeMap places a point where d3's geoAlbers fitted to the outline puts it" do
    assert_equal [ 391.6, 134.5 ], HomeMap.point(-87.65, 41.85), "Chicago, as d3-geo projects it"
  end

  private
    def sample(chart)
      { map: { count: 1, dots: [ { plants: [ { name: "A", slug: "a" } ], x: 1, y: 1 } ] }, bars: { rows: [ { label: "A", value: 1 } ] },
        columns: { columns: [ { label: "1", value: 1 } ] }, split: { parts: [ { label: "A", value: 1 }, { label: "B", value: 1 } ] } }.fetch(chart)
    end
end
