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
      assert_select "h2 .nd-chart__tfull", "Where US reactor fuel comes from"
      assert_select "h2 .nd-chart__tshort", "Where US fuel comes from", "phones' title"
      assert_select ".nd-chart__src", "Source: nrc.gov"
      assert_select ".nd-chart__more", "Fuel and materials →"
      assert_select ".nd-chart__name", "Centrus Energy"
    end
    assert_select "a.nd-chart--small[data-home-chart=newest][href='/updates'] h2", "Newest in the directory"
    assert_select "a.nd-chart--small[data-home-chart=categories][href='/companies'] h2", "What the companies do"
    assert_select "a.nd-chart a", count: 0, message: "no link inside a card link"
  end

  test "B with no whole set of charts draws A's page, named B with a fallback flag so the readout can leave it out" do
    get root_path(home: "b")

    assert_select "meta[name=home-variant][content=B][data-forced=true][data-fallback=true]"
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

  test "the owners card names the operator, and every company, by its short name, the full one in the title (#909)" do
    vogtle = cite!(plant("Plant Vogtle"))
    { "Georgia Power Company" => [ 45.7, "Georgia Power" ], "Oglethorpe Power" => [ 54.3, nil ] }.each do |name, (pct, short)|
      cite!(link(cite!(company(name, short_name: short)), "owns", vogtle)).update!(ownership_pct: pct)
    end
    cite!(link(cite!(company("Southern Nuclear Operating Co., Inc.", short_name: "Southern Nuclear")), "operates", vogtle))
    html = ApplicationController.render(partial: "home/charts/owners", locals: { data: HomeCharts.new.owners, size: :small })
    card = Nokogiri::HTML.fragment(html)

    assert_equal "Each owner's share. Southern Nuclear runs it.", card.at_css(".nd-chart__sub").text
    assert_equal [ "Oglethorpe Power", "Georgia Power" ], card.css(".nd-chart__barname").map(&:text), "largest share first"
    assert_equal "Georgia Power Company", card.css(".nd-chart__barname").last["title"]
  end
end
