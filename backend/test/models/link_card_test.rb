require "test_helper"

# The link-preview cards (#245), to Design's spec on #245 (direction E).
class LinkCardTest < ActiveSupport::TestCase
  # Stands in for PlantProfile: only what for_plant reads.
  Plant = Struct.new(:name, :facility_type, :state, :units, :capacity_mw, :operators, :owners, keyword_init: true) do
    def current_companies_for(type) = { "operates" => operators, "owns" => owners }.fetch(type).to_a.map { |name| Struct.new(:name).new(name) }
  end

  Unit = Struct.new(:status)

  def vogtle(**overrides)
    Plant.new(name: "Plant Vogtle", facility_type: "power_reactor", state: "GA", units: Array.new(4) { Unit.new("operating") }, capacity_mw: BigDecimal("4530"),
      operators: [ "Southern Nuclear" ], owners: [ "Georgia Power", "Oglethorpe Power", "MEAG Power", "Dalton Utilities" ], **overrides)
  end

  def name_lines(name) = LinkCard.new(squares: [ "#fff" ], name:).send(:name_lines)

  test "the name takes the largest step at which it fits two lines" do
    assert_equal [ 190, [ "KAIROS POWER" ] ], name_lines("Kairos Power")
    assert_equal [ 190, [ "PLANT VOGTLE" ] ], name_lines("Plant Vogtle")
    assert_equal [ 132, [ "SUSQUEHANNA STEAM", "ELECTRIC STATION" ] ], name_lines("Susquehanna Steam Electric Station")
  end

  test "a two-line name with a role line starts at 160, keeping 24px clear above and below (Design)" do
    roles = [ { "Operated by" => [ "Pacific Gas and Electric Company" ], "Owned by" => [] }, :role ]

    assert_equal [ 190, [ "DIABLO", "CANYON" ] ], name_lines("Diablo Canyon"), "no role line: 190 fits"
    assert_equal [ 160, [ "DIABLO CANYON" ] ], LinkCard.new(squares: [ "#fff" ], name: "Diablo Canyon", subline: roles).send(:name_lines)
    assert_equal [ 170, [ "NUCLEAR", "DIRECTORY" ] ], LinkCard.default.send(:name_lines), "the default card's fixed size still fits"
  end

  test "a name too long even at the smallest step ends its second line with '…' at a word" do
    size, lines = name_lines("A Name So Extraordinarily Long That It Cannot Possibly Fit On Two Lines At Any Of The Sizes")

    assert_equal 92, size
    assert_equal 2, lines.size
    assert lines.last.end_with?("…")
    assert_match(/\w…\z/, lines.last)
  end

  test "a plant card: type and state, role line with '+N', reactors and capacity as the page shows them" do
    card = LinkCard.for_plant(vogtle)

    assert_equal "Power plant · Georgia", card.label
    assert_equal "Operated by Southern Nuclear · Owned by Georgia Power + 3", card.role_text
    assert_equal "4 operating reactors · 4,530 MW", card.footer_right
    assert_equal [ LinkCard::CATEGORY_COLORS["plants"] ], card.squares
    assert_equal "Plant Vogtle: Power plant · Georgia. Operated by Southern Nuclear · Owned by Georgia Power, Oglethorpe Power, " \
      "MEAG Power and Dalton Utilities. 4 operating reactors · 4,530 MW.", card.alt
  end

  test "a role line too long even with one name each keeps its counts and shortens the longest name" do
    card = LinkCard.for_plant(vogtle(name: "Susquehanna", operators: [ "Susquehanna Nuclear, LLC" ],
      owners: [ "Talen Energy", "Allegheny Electric Cooperative" ]))

    assert_equal "Operated by Susquehanna Nuclear… · Owned by Talen Energy + 1", card.role_text
  end

  test "a plant with units of several statuses keeps each status whole on the image, or says it shorter" do
    dresden = LinkCard.for_plant(vogtle(name: "Dresden", units: [ Unit.new("operating"), Unit.new("operating"), Unit.new("decommissioning") ],
      capacity_mw: BigDecimal("1845")))

    assert_equal "2 operating reactors, 1 being decommissioned · 1,845 MW", dresden.footer_right
    assert_equal "3 reactors, 2 operating · 1,845 MW", dresden.send(:footer_drawn).last, "never cut mid-status"
    assert_includes dresden.alt, "2 operating reactors, 1 being decommissioned · 1,845 MW."

    shut = LinkCard.for_plant(vogtle(units: [ Unit.new("shut_down"), Unit.new("decommissioning") ], capacity_mw: nil))
    assert_equal "2 reactors", shut.send(:footer_drawn).last
  end

  test "what isn't known is left off, never shown as 0 or blank" do
    card = LinkCard.for_plant(vogtle(facility_type: "fuel_facility", state: nil, units: [], capacity_mw: nil, operators: [], owners: [ "Orano" ]))
    assert_equal [ "Fuel plant", "Owned by Orano", nil ], [ card.label, card.role_text, card.footer_right ]

    bare = LinkCard.for_plant(vogtle(facility_type: nil, state: nil, units: [ Unit.new(nil) ], capacity_mw: nil, operators: [], owners: []))
    assert_equal [ nil, nil, "1 unit" ], [ bare.label, bare.subline, bare.footer_right ]
    assert_equal "Plant Vogtle. 1 unit.", bare.alt
  end

  # Stands in for CompanyProfile: only what for_company reads.
  Company = Struct.new(:name, :hq_city, :hq_state, :shown_roles, :plant_links, :deals, :category, keyword_init: true)
  Link = Struct.new(:relationship_type, :facility, :started_on, :ended_on)

  def link(type, started_on: nil, ended_on: nil) = Link.new(type, Facility.new(name: "Site #{rand}"), started_on, ended_on)

  def kairos(**overrides)
    # Its roles sorted by name put "Molten salt coolant" first; the label still leads with the category's role (Design's QA).
    Company.new(name: "Kairos Power", hq_city: "Alameda", hq_state: "CA",
      shown_roles: [ Role.new(key: "molten_salt_coolant", name: "Molten salt coolant"), Role.new(key: "reactor_vendor", name: "Reactor vendor") ]
        .map { |role| Struct.new(:role).new(role) },
      plant_links: [ link("operates"), link("owns"), link("owns") ], deals: Array.new(3), category: Category.find("reactor-developers"), **overrides)
  end

  test "a company card: role and HQ, then up to two facts in order" do
    profile = kairos

    card = LinkCard.for_company(profile)

    assert_equal [ "Reactor developer · Alameda, CA", "Operates 1 plant · Owns stakes in 2 plants" ], [ card.label, card.footer_right ]
    assert_equal [ LinkCard::CATEGORY_COLORS["reactor-developers"] ], card.squares

    profile.category = nil
    assert_equal "Molten salt coolant · Alameda, CA", LinkCard.for_company(profile).label, "no category: its first role"
  end

  test "the footer drops a whole fact rather than cut one, as drawn" do
    card = LinkCard.for_company(kairos)

    assert_equal "Operates 1 plant · Owns stakes in 2 plants", card.footer_right, "both facts, for the alt text"
    assert_equal "Operates 1 plant", card.send(:footer_drawn).last, "the second doesn't fit beside the wordmark"
    assert_equal "4 operating reactors · 4,530 MW", LinkCard.for_plant(vogtle).send(:footer_drawn).last
  end

  test "a company's HQ shows only when its page shows it (a source backs it)" do
    assert_equal "Reactor developer", LinkCard.for_company(kairos(hq_city: nil, hq_state: nil)).label
  end

  test "a company's plant counts are in the present tense: only links in effect today" do
    links = [ link("operates", started_on: 1.year.from_now.to_date), link("operates", ended_on: Date.current), link("owns", ended_on: 1.day.from_now.to_date),
      link("owns", started_on: Date.current) ]

    assert_equal "Owns stakes in 2 plants · 3 deals", LinkCard.for_company(kairos(plant_links: links)).footer_right
  end

  test "a name that's one word too wide for a line is cut, with no empty second line" do
    size, lines = name_lines("A" * 40)

    assert_equal [ 92, 1 ], [ size, lines.size ]
    assert lines.first.end_with?("…")
    assert_operator LinkCard::Font.width(lines.first, font: :anton, size: 92), :<=, LinkCard::TEXT_WIDTH
  end

  test "a role line with long names on both sides shortens them in turn and keeps both counts" do
    card = LinkCard.for_plant(vogtle(operators: [ "GE Vernova Hitachi Nuclear Energy", "Another Operator" ],
      owners: [ "Old Dominion Electric Cooperative", "Another Owner" ]))

    assert_match(/\AOperated by .+ \+ 1 · Owned by .+ \+ 1\z/, card.role_text)
    assert_operator LinkCard::Font.width(card.role_text, font: :mono, size: 28), :<=, LinkCard::TEXT_WIDTH

    # Both down to one long word and still too wide: letters go, the counts stay.
    card = LinkCard.for_plant(vogtle(operators: [ "EnergySolutions Government Group", "Another Operator" ],
      owners: [ "EnergySolutions Waste Management", "Another Owner" ]))
    assert_match(/\AOperated by Energy\S*… \+ 1 · Owned by Energy\S*… \+ 1\z/, card.role_text)
    assert_operator LinkCard::Font.width(card.role_text, font: :mono, size: 28), :<=, LinkCard::TEXT_WIDTH
  end

  test "the default card's footer keeps 48px between its two sides, its left at 26px (Design's QA)" do
    left, right = LinkCard.default.footer_left, LinkCard.default.footer_right
    at30 = LinkCard::Font.width(left, font: :mono, size: 30) + 48 + LinkCard::Font.width(right, font: :mono, size: 30)
    at26 = LinkCard::Font.width(left, font: :mono, size: 26) + 48 + LinkCard::Font.width(right, font: :mono, size: 30)

    assert_operator at30, :>, LinkCard::TEXT_WIDTH, "too tight at 30px, so it steps down"
    assert_operator at26, :<=, LinkCard::TEXT_WIDTH
  end

  test "a category card counts what the category lists" do
    assert_equal "11 companies", LinkCard.for_category(Category.find("reactor-developers"), 11).footer_right
    assert_equal "1 plant or site", LinkCard.for_category(Category.find("plants"), 1).footer_right
    assert_equal "88 plants and sites", LinkCard.for_category(Category.find("plants"), 88).footer_right
  end

  test "the default card: three squares, the tagline as Tosin wrote it, no wordmark" do
    card = LinkCard.default

    assert_equal 3, card.squares.size
    assert_equal "Who's behind the Nuclear Supply Chain", card.alt
    assert_equal [ "Companies · plants and sites · deals", "nuclear-directory.org" ], [ card.footer_left, card.footer_right ]
  end

  test "the digest changes when anything drawn changes, and only then" do
    assert_equal LinkCard.for_plant(vogtle).digest, LinkCard.for_plant(vogtle).digest
    assert_not_equal LinkCard.for_plant(vogtle).digest, LinkCard.for_plant(vogtle(capacity_mw: BigDecimal("4536"))).digest
    assert_match(/\A\h{16}\z/, LinkCard.default.digest)
  end

  test "a card is outlines, not text, and rasterizes to a 1200×630 PNG" do
    card = LinkCard.for_plant(vogtle)

    assert_no_match(/<text/, card.svg)
    image = Vips::Image.new_from_buffer(card.png, "")
    assert_equal [ 1200, 630 ], [ image.width, image.height ]
  end
end
