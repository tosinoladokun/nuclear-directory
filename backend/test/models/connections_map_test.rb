require "test_helper"
require_relative "../support/connections_fixtures"

class ConnectionsMapTest < ActiveSupport::TestCase
  include ConnectionsFixtures

  test "a plant's unit links fold into one arrow per company, owners and the operator each pointing at the site" do
    map = ConnectionsMap.for_plant(PlantProfile.new(build_vogtle))

    assert_equal [ "Dalton Utilities owns Plant Vogtle", "Georgia Power owns Plant Vogtle", "MEAG Power owns Plant Vogtle",
      "Oglethorpe Power Corporation owns Plant Vogtle", "Southern Nuclear Operating Company operates Plant Vogtle",
      "Westinghouse Electric Company supplies Plant Vogtle" ], map.edges.map(&:sentence).sort
    operates = map.edges.find { |edge| edge.verb == "operates" }
    assert_equal 4, operates.facts.size, "units 1 to 4 make one operates arrow"
    assert_includes operates.details, "Vogtle Unit 1, Vogtle Unit 2, Vogtle Unit 3, Vogtle Unit 4"
    assert_includes map.edges.find { |edge| edge.giver.name == "Georgia Power" }.details, "45.7% share"
    assert_equal "Reactor design", map.edges.find { |edge| edge.verb == "supplies" }.details.first
    assert_equal [ 6, 0 ], [ map.companies, map.plants ]
  end

  test "only signed deals are arrows; a conditional offer is a note with its stage" do
    map = ConnectionsMap.for_company(CompanyProfile.new(build_terrapower))

    assert_equal [ "Global Nuclear Fuel–Americas supplies TerraPower", "Meta funds TerraPower", "TerraPower owns Kemmerer Unit 1",
      "U.S. Department of Energy funds TerraPower" ], map.edges.map(&:sentence).sort
    note = map.notes.sole
    assert_equal "Conditional · Apr 2025", note.stage
    assert_equal "The Department of Energy offered HALEU fuel, subject to conditions.", note.text
    assert_equal [ "example.org" ], note.sources.map(&:domain)
  end

  test "the stage rule: a power deal needs Signed; other deals are signed unless an earlier stage or pending" do
    signed = ->(type, description) { ConnectionsMap.signed?(Relationship.new(relationship_type: type, description:)) }

    assert signed.("offtake_with", "Signed 20-year PPA (Sept 2024) for Crane.")
    assert_not signed.("offtake_with", "Agreement (Oct 2024): Amazon funds the feasibility phase.")
    assert_not signed.("offtake_with", nil)
    assert signed.("supplies", "Award (early 2023) from NNSA: about $14M.")
    assert signed.("invests_in", nil)
    [ "MOU (2025): to explore", "Framework (Oct 2024): aim to", "Term sheet (2025)", "Binding term sheet (2025)", "Letter of intent: 100 MW",
      "Non-binding letter of intent (Nov 2024)", "Preorder (2024)", "Option to buy", "Conditional (Apr 2025): HALEU", "Announced plan (Oct 2023)",
      "Agreement to explore an SMR", "Partnership, early development", "Strategic agreement with capital", "Prepayment (2024): $25M" ]
      .each { |description| assert_not signed.("supplies", description), description }
    assert_not signed.("funds", "Award, pending final approval")
  end

  test "more than six plants fold into one node, one arrow per verb, and open into every plant" do
    map = ConnectionsMap.for_company(CompanyProfile.new(build_constellation))

    assert map.folds?
    folded = map.folded
    fold = folded.find { |edge| edge.receiver.fold? }.receiver
    assert_equal "13 plants", fold.name
    assert_equal [ "Constellation operates 13 plants", "Constellation owns 13 plants" ], folded.select { |edge| edge.receiver.fold? }.map(&:sentence).sort
    assert_equal 13, map.opened.count { |edge| edge.verb == "operates" }
    assert_equal 4, map.opened.count { |edge| edge.verb == "sells power to" }
    assert_equal "Announced plan · May 2023", map.notes.sole.stage
    assert_equal [ 6, 13 ], [ map.companies, map.plants ], "Helion is in a note, not on the map"
  end

  test "every arrow and note names a web source, or isn't shown" do
    build_vogtle
    unsourced = company("Unsourced Owner")
    link(unsourced, "owns", @vogtle).update!(ownership_pct: 1)
    map = ConnectionsMap.for_plant(PlantProfile.new(@vogtle))

    assert_not_includes map.edges.map { |edge| edge.giver.name }, "Unsourced Owner"
    assert map.edges.all? { |edge| edge.sources.any? && edge.sources.all? { |source| Source.web_address?(source.url) } }
  end

  test "an ended link isn't a current connection" do
    build_vogtle
    FacilityRelationship.find_by!(organization: Organization.find_by!(name: "Dalton Utilities")).update!(ended_on: 1.year.ago.to_date)
    map = ConnectionsMap.for_plant(PlantProfile.new(@vogtle))

    assert_not_includes map.edges.map { |edge| edge.giver.name }, "Dalton Utilities"
  end

  test "short names drop the legal ending; a name without one has none" do
    assert_equal "Oglethorpe Power", ConnectionsMap.short_name("Oglethorpe Power Corporation")
    assert_equal "Southern Nuclear Operating", ConnectionsMap.short_name("Southern Nuclear Operating Co., Inc.")
    assert_nil ConnectionsMap.short_name("Georgia Power")
  end

  test "the layout bundles arrows that share a verb and puts one label on the trunk" do
    map = ConnectionsMap.for_plant(PlantProfile.new(build_vogtle))
    [ ConnectionsMap::Layout::WIDE, ConnectionsMap::Layout::NARROW ].each do |size|
      layout = ConnectionsMap::Layout.new(map.edges, centre: map.centre, size:, prefix: "t")
      owns = layout.groups.find { |group| group.verb == "owns" }

      assert owns.bundle?, size.key
      assert_equal 4, owns.members.size
      assert owns.members.none?(&:arrow), "fan-in: the arrowhead is on the trunk (#{size.key})"
      assert_equal owns.trunk, owns.label_path
      assert_equal 7, layout.nodes.size
      assert layout.nodes.all? { |node| node.x.between?(0, size.width) && node.y.between?(0, layout.height) }, size.key
    end
  end
end
