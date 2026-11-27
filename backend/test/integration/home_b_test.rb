require "test_helper"
require_relative "../support/directory_builders"

# Homepage B (#909): the search, a link to the data, then one large and two small chart cards. Each card is a question
# and its chart: no subtitle, no source line. The title row links to the list with a small ↗; rows and dots that are one
# record link to its page (#949).
class HomeBTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    operating_plant("Byron", state: "IL", latitude: 42.07, longitude: -89.28, units: [ [ 1164.0, "PWR" ], [ 1136.0, "PWR" ] ])
    operating_plant("Plant Vogtle", state: "GA", latitude: 33.14, longitude: -81.76, units: [ [ 1150.0, "PWR" ], [ 1114.0, "PWR" ] ])
    operating_plant("Dresden", state: "IL", latitude: 41.39, longitude: -88.27, units: [ [ 894.0, "BWR" ] ])
  end

  test "B: the download link, then three chart cards, the large one first, each titled with a link and no source line" do
    get root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")

    assert_select "meta[name=home-variant][content=B][data-forced=true]"
    assert_select ".nd-catgrid", count: 0, message: "B has no category cards (Tosin approved; Browse keeps them a tap away)"
    assert_select ".nd-home__download a[href='/data'][data-home-download]", text: "Download the data"
    assert_select ".nd-charts > div.nd-chart", 3
    assert_select ".nd-charts > div.nd-chart:first-child.nd-chart--large[data-home-chart=plant_map]" do
      assert_select "a.nd-chart__head[data-home-chart-link][href='/companies?category=plants&status=operating']" do
        assert_select "h2.nd-chart__title", "Where are the 3 operating US nuclear plants?"
        assert_select "h2 span, h2[title]", count: 0, message: "the whole question, one form only (#961)"
        assert_select ".nd-chart__go svg"
      end
      assert_select "svg.nd-chartmap[role=group][aria-label='Map of the 3 operating US nuclear plants'] circle.nd-chartmap__dot", 3
      # #940, #949: each dot is a link to its plant, named with its state; the label is filled in on hover, tap or focus.
      byron = Facility.find_by(name: "Byron", parent_id: nil)
      assert_select ".nd-chartmap__spot[data-state='Illinois'] a.nd-chartmap__link[href='/plants/#{byron.slug}'][aria-label='Byron, Illinois'][data-name='Byron'][data-home-record=plant] circle.nd-chartmap__dot"
      assert_select "a.nd-chartmap__link", 3
      assert_select "circle.nd-chartmap__dot title", count: 0, message: "no browser tooltip on top of the label"
      assert_select ".nd-chartmap-wrap[data-controller=home-map] .nd-chartmap__label[hidden][aria-hidden=true]"
      assert_select "circle.nd-chartmap__ring[r='12'][visibility=hidden]"
    end
    assert_select "div.nd-chart--small[data-home-chart=reactor_sizes]" do
      assert_select "h2", "How big are US reactors?"
      assert_equal [ "Reactors", "Reactor size (MW, net summer)" ], css_select(".nd-axis__name").map(&:text)
      assert_equal %w[600 900 1,100 1,300], css_select(".nd-chartcols__xedge").map(&:text)
    end
    assert_select "div.nd-chart--small[data-home-chart=reactor_types] .nd-chartsplit__row", 2
    assert_select ".nd-chart__go svg", 3
    assert_select ".nd-chart__src, .nd-chart__sub", count: 0, message: "no source line and no subtitle (Tosin, 25 Nov)"
    assert_select "a a", count: 0, message: "no link inside a link"
    assert_select "[data-home-chart=reactor_sizes] a:not(.nd-chart__head), [data-home-chart=reactor_types] a:not(.nd-chart__head)", count: 0, message: "columns and split bars have no single records: only the title links"
  end

  test "bars: the category axis named above the names, the value axis's ticks and unit under them, a value beside each bar" do
    get root_path(home: "b", charts: "state_power,reactor_sizes,reactor_types")

    assert_select "div.nd-chart--large[data-home-chart=state_power]" do
      assert_select ".nd-chartbars__catname", "State"
      assert_equal %w[Illinois Georgia], css_select(".nd-chartbars__label").map(&:text)
      assert_equal %w[3.2 2.3], css_select(".nd-chartbars__value").map(&:text)
      assert_equal %w[0 4], css_select(".nd-chartbars__tick").map(&:text)
      assert_select ".nd-chartbars__valname", "Capacity (GW, net summer)"
      assert_select "span.nd-chartbars__row", 2
      assert_select "a.nd-chartbars__row", count: 0, message: "states are ours, not records: plain rows"
    end
  end

  test "a bar that is a plant or a company links to its page, the whole row one link (#949)" do
    vendor = cite!(organizations(:westinghouse).tap { |org| org.update_columns(short_name: "Westinghouse", **verification(true)) })
    Facility.where(parent_id: nil).find_each { |site| cite!(link(vendor, "vendor_for", site)) }
    get root_path(home: "b", charts: "largest_plants,reactor_vendors,reactor_types")

    vogtle = Facility.find_by(name: "Plant Vogtle", parent_id: nil)
    assert_select "div.nd-chart--large[data-home-chart=largest_plants] a.nd-chartbars__row[href='/plants/#{vogtle.slug}'][data-home-record=plant]" do
      assert_select ".nd-chartbars__label", "Plant Vogtle"
      assert_select ".nd-chartbars__track .nd-chartbars__bar"
      assert_select ".nd-chartbars__value", "2.3"
    end
    assert_select "[data-home-chart=largest_plants] a.nd-chartbars__row", 3
    assert_select "[data-home-chart=reactor_vendors] a.nd-chartbars__row[href='/companies/#{vendor.slug}'][data-home-record=company]", 1
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

  # The homepage's clicks (categories, charts, records, the download link) are recorded, so Privacy says so (27 Nov list).
  test "the privacy page names the homepage clicks" do
    get "/privacy"
    assert_includes response.body, "and what you clicked on it"
  end
end
