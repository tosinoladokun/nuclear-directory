require "test_helper"
require_relative "../support/directory_builders"

# Homepage B (#909): the search, a link to the data, then one large and two small chart cards. Each card is a question
# and its chart: no subtitle, no source line, the whole card one link with a small ↗.
class HomeBTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    operating_plant("Byron", state: "IL", latitude: 42.07, longitude: -89.28, units: [ [ 1164.0, "PWR" ], [ 1136.0, "PWR" ] ])
    operating_plant("Plant Vogtle", state: "GA", latitude: 33.14, longitude: -81.76, units: [ [ 1150.0, "PWR" ], [ 1114.0, "PWR" ] ])
    operating_plant("Dresden", state: "IL", latitude: 41.39, longitude: -88.27, units: [ [ 894.0, "BWR" ] ])
  end

  test "B: the download link, then three chart cards, the large one first, each a whole-card link with no source line" do
    get root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")

    assert_select "meta[name=home-variant][content=B][data-forced=true]"
    assert_select ".nd-catgrid", count: 0, message: "B has no category cards (Tosin approved; Browse keeps them a tap away)"
    assert_select ".nd-home__download a[href='/data'][data-home-download]", text: "Download the data"
    assert_select ".nd-charts > a.nd-chart", 3
    assert_select ".nd-charts > a.nd-chart:first-child.nd-chart--large[data-home-chart=plant_map][href='/companies?category=plants&status=operating']" do
      assert_select "h2 .nd-chart__tfull", "Where are the 3 operating US nuclear plants?"
      assert_select "h2 .nd-chart__tshort", "Where are US plants?"
      assert_select "svg.nd-chartmap[aria-label='Map of the 3 operating US nuclear plants'] circle.nd-chartmap__dot", 3
    end
    assert_select "a.nd-chart--small[data-home-chart=reactor_sizes]" do
      assert_select "h2", "How big are US reactors?"
      assert_select "h2 .nd-chart__tshort", count: 0, message: "the whole question fits at 320, so it has no short form (Design, #935)"
      assert_equal [ "Reactors", "Reactor size (MW, net summer)" ], css_select(".nd-axis__name").map(&:text)
      assert_equal %w[600 900 1,100 1,300], css_select(".nd-chartcols__xedge").map(&:text)
    end
    assert_select "a.nd-chart--small[data-home-chart=reactor_types] .nd-chartsplit__row", 2
    assert_select ".nd-chart__go svg", 3
    assert_select ".nd-chart__src, .nd-chart__sub", count: 0, message: "no source line and no subtitle (Tosin, 25 Nov)"
    assert_select "a.nd-chart a", count: 0, message: "no link inside a card link"
  end

  test "bars: the category axis named above the names, the value axis's ticks and unit under them, a value beside each bar" do
    get root_path(home: "b", charts: "state_power,reactor_sizes,reactor_types")

    assert_select "a.nd-chart--large[data-home-chart=state_power]" do
      assert_select ".nd-chartbars__catname", "State"
      assert_equal %w[Illinois Georgia], css_select(".nd-chartbars__label").map(&:text)
      assert_equal %w[3.2 2.3], css_select(".nd-chartbars__value").map(&:text)
      assert_equal %w[0 4], css_select(".nd-chartbars__tick").map(&:text)
      assert_select ".nd-chartbars__valname", "Capacity (GW, net summer)"
    end
  end

  test "B with no set of charts draws A's page, named B with a fallback flag so the readout can leave it out" do
    Facility.where.not(parent_id: nil).delete_all
    get root_path(home: "b")

    assert_select "meta[name=home-variant][content=B][data-forced=true][data-fallback=true]"
    assert_select ".nd-charts", count: 0
    assert_select ".nd-home__cats"
  end

  test "A has no charts and no download link" do
    get root_path(home: "a")

    assert_select ".nd-charts", count: 0
    assert_select ".nd-home__download", count: 0
  end

  test "only a forced visit can name its cards" do
    get root_path(charts: "plant_map,reactor_sizes,reactor_types")
    assert_select ".nd-charts", count: 0, message: "the test is off, so a plain visit is A"
  end

  test "the privacy page names the chart and download clicks" do
    get "/privacy"
    assert_includes response.body, "which category, chart or download link you clicked"
  end
end
