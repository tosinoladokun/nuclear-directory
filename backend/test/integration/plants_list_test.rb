require "test_helper"
require_relative "../support/directory_builders"

# The Plants and sites list (#614): status chips with counts, its own filters (type, reactor, state), the sorts (largest
# first by default, A to Z, most units), and rows in columns. Nothing is guessed: a site without sourced facts keeps
# empty cells and sorts last by capacity.
class PlantsListTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    @big = cite!(plant("Big Station", facility_type: "power_reactor", status: "operating", reactor_type: "PWR", city: "Waynesboro", state: "GA"))
    cite!(plant("Big Station Unit 1", parent: @big, capacity_mw: 1100, status: "operating", reactor_type: "PWR"))
    cite!(plant("Big Station Unit 2", parent: @big, capacity_mw: 1100, status: "operating", reactor_type: "PWR"))
    @small = cite!(plant("Small Station", facility_type: "power_reactor", status: "operating", reactor_type: "BWR", city: "Oak Ridge", state: "TN"))
    cite!(plant("Small Station Unit 1", parent: @small, capacity_mw: 300, status: "operating", reactor_type: "BWR"))
    cite!(plant("Test Rig", facility_type: "research_reactor", status: "under_construction", city: "Idaho Falls", state: "ID"))
    cite!(plant("Future Plant", facility_type: "power_reactor", status: "planned", state: "TX"))
    plant("Bare Name") # verified, no sourced facts
  end

  def names = css_select("a.nd-prow .nd-prow__name").map { |node| node.text.strip }

  test "status chips under the heading count each status; All is the default, one at a time" do
    get companies_path(category: "plants")

    assert_select ".nd-statuschips a.nd-chip[aria-current=page]", /All\s+5/
    assert_select ".nd-statuschips a.nd-chip", text: /Operating\s+2/
    assert_select ".nd-statuschips a.nd-chip", text: /Under construction\s+1/
    assert_select ".nd-statuschips a.nd-chip", text: /Planned\s+1/
    assert_select ".nd-statuschips a.nd-chip", text: /Restart under review/, count: 0, message: "a status with no rows has no chip"
    assert_select ".nd-statuschips .nd-st__mark", minimum: 3

    get companies_path(category: "plants", status: "operating")
    assert_equal [ "Big Station", "Small Station" ], names
    assert_select ".nd-statuschips a.nd-chip[aria-current=page]", /Operating/
  end

  test "the filters are type, reactor and state, with only options that have rows" do
    get companies_path(category: "plants")
    assert_select "select[name=type] option", text: "Power plant"
    assert_select "select[name=type] option", text: "Test reactor"
    assert_select "select[name=type] option", text: "Mine", count: 0
    assert_select "select[name=reactor] option", text: "Pressurized water (PWR)"
    assert_select "select[name=reactor] option", text: "Boiling water (BWR)"
    assert_select "select[name=state]"
    assert_select "a", text: "Clear filters", count: 0

    get companies_path(category: "plants", type: "research_reactor")
    assert_equal [ "Test Rig" ], names
    assert_select "a", text: "Clear filters"

    get companies_path(category: "plants", reactor: "BWR")
    assert_equal [ "Small Station" ], names

    get companies_path(category: "plants", state: "GA", status: "operating")
    assert_equal [ "Big Station" ], names

    get companies_path(category: "plants", type: "not_a_type", reactor: "nope", status: "zzz")
    assert_equal 5, names.size, "unknown values are dropped, not applied"
  end

  test "largest first by default (rows with no capacity last); A to Z and most units are options" do
    get companies_path(category: "plants")
    assert_equal [ "Big Station", "Small Station" ], names.first(2)
    assert_includes names.last(3), "Bare Name"
    assert_select "select[name=sort] option[selected][value=capacity]", "Largest first"

    get companies_path(category: "plants", sort: "name")
    assert_equal names.sort_by(&:downcase), names

    get companies_path(category: "plants", sort: "units")
    assert_equal "Big Station", names.first
  end

  test "rows line up under a header: plant or site, status, type, units, capacity, location" do
    get companies_path(category: "plants")

    assert_select ".nd-lines--plants .nd-lines__head span", text: /Plant or site|Status|Type|Units|Capacity|Location/, count: 6
    assert_select "a.nd-prow[href='/plants/big-station']" do
      assert_select ".nd-prow__status .nd-st", /Operating/
      assert_select ".nd-prow__type", "Power plant"
      assert_select ".nd-prow__units", /\A2/
      assert_select ".nd-prow__cap", "2,200 MW"
      assert_select ".nd-prow__place", /Waynesboro/
    end
    assert_select "a.nd-prow[href='/plants/bare-name']" do
      assert_select ".nd-prow__status .nd-st", count: 0
      assert_select ".nd-prow__cap", text: ""
    end
  end

  test "chips, Clear filters and Clear search keep the search and the other filters" do
    get companies_path(category: "plants", q: "station", type: "power_reactor")

    assert_select ".nd-statuschips a.nd-chip[href*='q=station']", minimum: 2
    assert_select "a", text: "Clear filters" do |links|
      assert_includes links.first["href"], "q=station"
      assert_not_includes links.first["href"], "type="
    end

    get companies_path(category: "plants", q: "zzzz-none", status: "operating", type: "power_reactor", reactor: "PWR")
    assert_select ".nd-notice a", "Clear search" do |links|
      %w[status=operating type=power_reactor reactor=PWR].each { |part| assert_includes links.first["href"], part }
    end
  end

  test "a stale technology is ignored on the plants list, and an unsourced reactor type is neither offered nor matched" do
    plant("Unsourced Reactor Site", facility_type: "power_reactor", status: "operating", reactor_type: "HTGR") # verified, no source
    get companies_path(category: "plants", technology: "fusion")
    assert_equal 5 + 1, names.size
    assert_select "select[name=reactor] option", text: "High-temperature gas", count: 0

    get companies_path(category: "plants", reactor: "HTGR")
    assert_equal 6, names.size, "an unsourced reactor type isn't a valid option, so it isn't applied"
  end

  test "under Largest first, rows with sourced facts come before the bare names (the ties)" do
    get companies_path(category: "plants")
    assert_equal "Bare Name", names.last, "the bare name is last among the rows with no capacity"
    assert_operator names.index("Test Rig"), :<, names.index("Bare Name")
    assert_select "a.nd-prow .nd-prow__mark.nd-catsq svg", minimum: 5, message: "the row mark is the icon square"
    assert_select ".nd-lines__head .nd-prow__place", "Location"
  end

  test "the unit word is there for screen readers on every row, whatever the layout" do
    get companies_path(category: "plants")
    assert_select "a.nd-prow[href='/plants/big-station'] .nd-prow__unit-word", /units/
  end

  test "the company lists keep their own filters, and the tag list is untouched" do
    get companies_path
    assert_select "select[name=technology]"
    assert_select "select[name=type]", 0
    assert_select "select[name=sort] option", text: "Largest first", count: 0
  end
end
