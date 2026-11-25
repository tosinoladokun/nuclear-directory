require "test_helper"
require_relative "../support/directory_builders"

# Homepage B (#909): the search, a link to the data, then one large and two small chart cards; each card one link.
class HomeBTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  def build_fuel_set
    fuel = role("fuel")
    %w[mining conversion fabrication].each { |key| role(key, parent: fuel) }
    enrichment = role("enrichment", parent: fuel)
    cite!(company("Centrus Energy", roles: [ enrichment ]), source: Source.create!(url: "https://www.nrc.gov/x", source_kind: "web_page"))
  end

  test "B: the download link, then three chart cards, the large one first, each a whole-card link with a source line" do
    build_fuel_set
    get root_path(home: "b")

    assert_select "meta[name=home-variant][content=B][data-forced=true]"
    assert_select ".nd-catgrid", count: 0, message: "B has no category cards (Tosin approved; Browse keeps them a tap away)"
    assert_select ".nd-home__download a[href='/data'][data-home-download]", text: "Download the data"
    assert_select ".nd-charts > a.nd-chart", 3
    assert_select ".nd-charts > a.nd-chart:first-child.nd-chart--large[data-home-chart=fuel][href='/companies?category=fuel']" do
      assert_select "h2", "Where US reactor fuel comes from"
      assert_select ".nd-chart__src", "Source: nrc.gov"
      assert_select ".nd-chart__more", "Fuel and materials →"
      assert_select ".nd-chart__name", "Centrus Energy"
    end
    assert_select "a.nd-chart--small[data-home-chart=newest][href='/updates'] h2", "Newest in the directory"
    assert_select "a.nd-chart--small[data-home-chart=categories][href='/companies'] h2", "What the companies do"
    assert_select "a.nd-chart a", count: 0, message: "no link inside a card link"
  end

  test "B with no whole set of charts stays A, still marked forced" do
    get root_path(home: "b")

    assert_select "meta[name=home-variant][content=A][data-forced=true]"
    assert_select ".nd-charts", count: 0
    assert_select ".nd-home__cats"
  end

  test "A has no charts and no download link" do
    build_fuel_set
    get root_path(home: "a")

    assert_select ".nd-charts", count: 0
    assert_select ".nd-home__download", count: 0
  end

  test "the privacy page names the chart and download clicks" do
    get "/privacy"
    assert_includes response.body, "which category, chart or download link you clicked"
  end
end
