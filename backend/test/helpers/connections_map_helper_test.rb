require "test_helper"
require_relative "../support/directory_builders"

class ConnectionsMapHelperTest < ActionView::TestCase
  include DirectoryBuilders
  include DirectoryHelper

  test "a plant's icon uses its type and reactors only once the site is verified and sourced" do
    pending_site = plant("Pending Site", verified: false, facility_type: "research_reactor")
    sourced = cite!(plant("Sourced Site", facility_type: "research_reactor"))
    map = ConnectionsMap.new(sourced)

    assert_equal "site-plant", map_node_icon(map, ConnectionsMap::Node.new(key: "a", name: "Pending Site", short_name: nil, kind: :plant, record: pending_site, members: []))
    assert_equal "site-research", map_node_icon(map, map.centre)
  end
end
