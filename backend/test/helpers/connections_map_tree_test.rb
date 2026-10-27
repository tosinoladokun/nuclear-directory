require "test_helper"
require_relative "../support/connections_fixtures"

# The phone tree and the spoken summary come from the same edges as the picture (#561).
class ConnectionsMapTreeTest < ActionView::TestCase
  include ConnectionsFixtures
  helper ConnectionsMapHelper

  test "the tree lists givers first, then receivers, by verb in the spec's order" do
    map = ConnectionsMap.for_plant(PlantProfile.new(build_vogtle))
    rows = map_tree_rows(map)

    assert_equal rows.map(&:inbound), rows.map(&:inbound).sort_by { |inbound| inbound ? 0 : 1 }, "givers, then receivers"
    inbound = rows.select(&:inbound).map(&:verb).uniq
    assert_equal inbound, inbound.sort_by { |verb| %w[funds supplies].index(verb) || 9 }
    outbound = rows.reject(&:inbound).map(&:verb).uniq
    assert_equal outbound, outbound.sort_by { |verb| [ "sells power to", "owns", "operates" ].index(verb) || 9 }
  end

  test "the summary says the same things the picture draws, in words" do
    map = ConnectionsMap.for_plant(PlantProfile.new(build_vogtle))
    summary = map_summary(map)

    assert summary.start_with?("Connections. Plant Vogtle: "), summary
    assert_includes summary, "owned by"
    map.edges.each { |edge| assert_includes summary, (edge.receiver.key == map.centre.key ? edge.giver.name : edge.receiver.name) }
  end
end
