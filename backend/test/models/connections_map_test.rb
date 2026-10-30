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
    assert_equal "U.S. Department of Energy", note.other.name, "named first: the description needn't name them"
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
    assert_equal [ "Constellation operates 13 plants", "Constellation owns 2 of 13 plants" ], folded.select { |edge| edge.receiver.fold? }.map(&:sentence).sort
    assert_equal [ "2 of 13: Clinton Clean Energy Center, Crane Clean Energy Center" ], folded.find { |edge| edge.verb == "owns" }.details
    assert_equal 13, map.opened.count { |edge| edge.verb == "operates" }
    assert_equal 4, map.opened.count { |edge| edge.verb == "sells power to" }
    assert_equal "Announced plan · May 2023", map.notes.sole.stage
    assert_equal [ 6, 13 ], [ map.companies, map.plants ], "Helion is in a note, not on the map"
  end

  test "an owner that also operates the same node is one 'owns and operates' arrow; different sets stay two" do
    build_vogtle
    owner = cite!(company("Both Co"))
    cite!(link(owner, "owns", @vogtle))
    cite!(link(owner, "operates", @vogtle))
    both = ConnectionsMap.for_plant(PlantProfile.new(@vogtle)).folded.select { |edge| edge.giver.name == "Both Co" }
    assert_equal [ ConnectionsMap::BOTH ], both.map(&:verb)
    assert_equal "Both Co owns and operates #{@vogtle.name}", both.first.sentence
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

  test "a plant with seven owners doesn't fold them: only neighbouring plants fold" do
    build_vogtle
    %w[One Two Three].each { |n| cite!(link(cite!(company("Owner #{n}")), "owns", @vogtle)).update!(ownership_pct: 0.1) }
    map = ConnectionsMap.for_plant(PlantProfile.new(@vogtle))

    assert_equal 7, map.edges.count { |edge| edge.verb == "owns" }
    assert_not map.folds?
  end

  test "an ended deal, parent or subsidiary isn't a current arrow or note" do
    build_terrapower
    ended = Relationship.where(to_organization: @terrapower, relationship_type: "supplies").find { |deal| deal.description.start_with?("Signed") }
    ended.update!(ended_on: 1.month.ago.to_date)
    parent = cite!(company("Former Parent"))
    cite!(link(@terrapower, "subsidiary_of", parent)).update!(ended_on: 1.year.ago.to_date)
    map = ConnectionsMap.for_company(CompanyProfile.new(@terrapower))

    assert_not_includes map.edges.map(&:sentence), "Global Nuclear Fuel–Americas supplies TerraPower"
    assert_not_includes map.edges.map(&:sentence), "Former Parent owns TerraPower"
  end

  test "a plant power deal that isn't signed yet is a note, not an arrow" do
    build_vogtle
    buyer = cite!(company("Oracle"))
    cite!(link(buyer, "offtakes_from", @vogtle)).update!(description: "Subscription for 100 MW, pending state PSC approval.")
    map = ConnectionsMap.for_plant(PlantProfile.new(@vogtle))

    assert_not map.edges.any? { |edge| edge.verb == "sells power to" }
    assert_equal "Subscription for 100 MW, pending state PSC approval.", map.notes.sole.text
  end

  test "short names drop the legal ending; a name without one has none" do
    assert_equal "Oglethorpe Power", ConnectionsMap.short_name("Oglethorpe Power Corporation")
    assert_equal "Southern Nuclear Operating", ConnectionsMap.short_name("Southern Nuclear Operating Co., Inc.")
    assert_nil ConnectionsMap.short_name("Georgia Power")
  end

  def layout_for(map, prefix: "t") = ConnectionsMap::Layout.new(map.folded, centre: map.centre, size: ConnectionsMap::Layout::WIDE, prefix:)

  test "straight lines at right angles: a trunk, a bus and a branch per company, arrowheads into the receivers (#682)" do
    map = ConnectionsMap.for_plant(PlantProfile.new(build_vogtle))
    layout = layout_for(map)

    assert layout.lines.all? { |line| line.path.match?(/\AM-?[\d.]+ -?[\d.]+[HV]-?[\d.]+\z/) }, "a move and one horizontal or vertical run: no curve"
    received = map.folded.count { |edge| edge.receiver.key == map.centre.key }.positive? ? 1 : 0 # the left trunk's arrowhead, into the record
    given = map.folded.count { |edge| edge.giver.key == map.centre.key } # one branch arrowhead per company on the right
    assert_equal received + given, layout.lines.count(&:arrow)
    assert_equal 696, layout.width, "the page's middle column"
    assert layout.nodes.all? { |node| node.x.between?(0, layout.width) && node.y.between?(0, layout.height) }
  end

  test "each group has its heading from the record's side, in the phone tree's order (#682)" do
    centre = cite!(company("Record Co", roles: [ role("utility") ]))
    cite!(link(cite!(company("Alpha Fund")), "invests_in", centre)).update!(description: "Series A.")
    cite!(link(cite!(company("Gamma Supply")), "supplies", centre))
    cite!(link(centre, "supplies", cite!(company("Delta Buyer"))))
    cite!(link(cite!(company("Epsilon Power")), "offtake_with", centre)).update!(description: "Signed: 10 MW.")
    map = ConnectionsMap.for_company(CompanyProfile.new(centre))
    layout = layout_for(map)

    left, right = layout.headings.partition { |heading| heading.anchor == "end" }
    assert_equal [ "FUNDED BY", "SUPPLIED BY" ], left.map(&:text), "what is done to the record, funds before supplies, as on a phone"
    assert_equal [ "SELLS POWER TO", "SUPPLIES" ], right.map(&:text)
    tree = Class.new { include ConnectionsMapHelper }.new.map_tree_rows(map).map { |row| [ row.inbound, row.verb ] }.uniq
    assert_equal tree.map { |inbound, verb| (inbound ? ConnectionsMapHelper::PASSIVE.fetch(verb) : verb).upcase }, left.map(&:text) + right.map(&:text), "both widths read in the same order"
  end

  test "no heading sits on a line, and the record's name is clear of both buses (#682)" do
    map = ConnectionsMap.for_plant(PlantProfile.new(build_vogtle))
    layout = layout_for(map)
    buses = layout.bus_x.values

    layout.headings.each do |heading|
      assert buses.none? { |x| (heading.x - x).abs < 4 }, "#{heading.text} is not on a bus"
    end
    gap = buses.max - buses.min
    assert_operator layout.centre.slot, :<=, gap, "the record's name fits between the buses"
    assert_operator layout.centre.slot, :>=, 100
  end

  test "givers are always on the left and receivers on the right, whatever the heights" do
    centre = cite!(company("Balanced Co", roles: [ role("utility") ]))
    %w[Alpha Beta].each { |name| cite!(link(cite!(company("#{name} Fund")), "invests_in", centre)).update!(description: "Series A.") }
    cite!(link(cite!(company("Gamma Supply")), "supplies", centre))
    map = ConnectionsMap.for_company(CompanyProfile.new(centre))
    layout = ConnectionsMap::Layout.new(map.edges, centre: map.centre, size: ConnectionsMap::Layout::WIDE, prefix: "t")
    x = layout.nodes.to_h { |placed| [ placed.node.name, placed.x ] }

    assert_operator x["Gamma Supply"], :<, layout.centre.x, "a supplier is a giver, so it stays left even when the left is taller"
    assert(%w[Alpha\ Fund Beta\ Fund].all? { |name| x[name] < layout.centre.x })
  end

  test "a partner that both funds the centre and buys its power is drawn once on each side" do
    centre = cite!(company("Two Way Co"))
    partner = cite!(company("Amazon Demo"))
    cite!(link(partner, "invests_in", centre))
    deal = cite!(link(partner, "offtake_with", centre))
    deal.update!(description: "Signed: 500 MW.")
    map = ConnectionsMap.for_company(CompanyProfile.new(centre))
    layout = ConnectionsMap::Layout.new(map.edges, centre: map.centre, size: ConnectionsMap::Layout::WIDE, prefix: "t")
    copies = layout.nodes.select { |placed| placed.node.name == "Amazon Demo" }

    assert_equal 2, copies.size
    assert_equal [ true, true ], [ copies.any? { |placed| placed.x < layout.centre.x }, copies.any? { |placed| placed.x > layout.centre.x } ]
  end

  test "a power deal is signed by its terms, not only its words; a framework never is" do
    centre = cite!(company("Terms Co"))
    buyer = cite!(company("Buyer Co"))
    deal = cite!(link(buyer, "offtake_with", centre))
    deal.update!(description: "5 GW supply.") # no word 'Signed'
    term = DealTerm.create!(link: deal, term_type: "offtake", capacity_mw: 5000, agreement: "ppa", status: "signed", **verification(true))
    term.evidence.create!(source: default_source, quote: "q", found_by: "human", confidence: 1)

    assert ConnectionsMap.signed?(deal.reload), "a signed PPA term makes it an arrow"
    term.update!(agreement: "framework", status: "announced")
    assert_not ConnectionsMap.signed?(deal.reload), "a framework is never an arrow"

    mou = cite!(link(cite!(company("Mou Buyer")), "offtake_with", centre))
    mou.update!(description: "")
    DealTerm.create!(link: mou, term_type: "offtake", agreement: "mou", capacity_mw: 100, **verification(true))
    assert_not ConnectionsMap.signed?(mou.reload), "a blank description with an MOU term is not a power sale"
  end

  test "a link that hasn't started yet isn't an arrow" do
    centre = cite!(company("Schedule Co"))
    later = cite!(link(cite!(company("Later Supplier")), "supplies", centre))
    later.update!(started_on: 1.year.from_now.to_date)
    now = cite!(link(cite!(company("Now Supplier")), "supplies", centre))
    map = ConnectionsMap.for_company(CompanyProfile.new(centre))

    assert_equal [ "Now Supplier supplies Schedule Co" ], map.edges.map(&:sentence)
  end

  test "an arrow to folded plants knows which plants its verb covers" do
    map = ConnectionsMap.for_company(CompanyProfile.new(build_constellation))
    folded = map.folded
    owns = folded.find { |edge| edge.verb == "owns" && edge.receiver.fold? }

    assert owns, "owns folds"
    assert_operator owns.members.size, :<=, owns.receiver.members.size
    assert_equal owns.covers, owns.members.size
  end
end
