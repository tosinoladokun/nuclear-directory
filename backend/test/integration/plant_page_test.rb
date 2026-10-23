require "test_helper"
require_relative "../support/directory_builders"

class PlantPageTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    @release = Source.create!(url: "https://www.georgiapower.com/vogtle-4", title: "Vogtle Unit 4 enters commercial operation",
      source_kind: "web_page", published_on: Date.new(2024, 4, 29))
    @nrc = Source.create!(url: "https://www.nrc.gov/vogtle", source_kind: "web_page")

    @vogtle = plant("Plant Vogtle", facility_type: "power_reactor", status: "operating", city: "Waynesboro", state: "GA",
      technology: technology("fission", "Fission"), verified_at: Time.zone.parse("2026-10-09"))
    @vogtle.evidence.create!(source: @nrc, found_by: "human", confidence: 1)
    @unit3 = cite!(plant("Unit 3", parent: @vogtle, reactor_type: "AP1000", capacity_mw: 1114, status: "operating", nrc_docket: "05200025"), source: @nrc)
    @unit4 = plant("Unit 4", parent: @vogtle, reactor_type: "AP1000", capacity_mw: 1114, status: "operating", nrc_docket: "05200026")
    @unit4.evidence.create!(source: @release, found_by: "human", confidence: 1)
    plant("Unit 5", parent: @vogtle, verified: false)

    @georgia = company("Georgia Power")
    @southern = company("Southern Nuclear")
    @westinghouse = company("Westinghouse Nuclear")
    owns = link(@georgia, "owns", @unit3)
    owns.update!(ownership_pct: 45.7, description: "Co-owned with Oglethorpe Power and MEAG Power.")
    owns.evidence.create!(source: @release, quote: "the project's co-owners", found_by: "human", confidence: 1)
    cite!(link(@southern, "operates", @vogtle), link(@westinghouse, "vendor_for", @vogtle), source: @nrc)
    link(company("Ghost Buyer", verified: false), "offtakes_from", @vogtle)
    link(company("Pending Owner"), "owns", @vogtle, verified: false)
  end

  test "a public plant's page shows its facts" do
    get plant_path(slug: "plant-vogtle")

    assert_response :success
    assert_select "title", "Plant Vogtle, Waynesboro, GA: owners and operator · Nuclear Directory"
    assert_select "main", 1
    assert_select "h1#profile-name", "Plant Vogtle"
    assert_select ".nd-tag", "Power plant"
    assert_select ".nd-tag", "Operating"
    assert_select ".nd-crumbs a[href=?]", "/companies?category=plants", text: "Plants and sites"
  end

  test "companies read left to right, link to their pages and carry sources" do
    get plant_path(slug: "plant-vogtle")

    assert_select "#companies-heading small", "3"
    assert_select ".nd-factrow", text: /Georgia Power\s+owns\s+Plant Vogtle, Unit 3/ do
      assert_select "a[href='/companies/georgia-power']", "Georgia Power"
      assert_select ".nd-factrow__detail", "45.7% share · Co-owned with Oglethorpe Power and MEAG Power."
      assert_select ".nd-quote", "“the project's co-owners”"
    end
    assert_select ".nd-factrow", text: /Southern Nuclear\s+operates\s+Plant Vogtle/
    assert_select ".nd-factrow", text: /Westinghouse Nuclear\s+is the reactor developer for\s+Plant Vogtle/
  end

  test "a unit that carries the plant's name isn't named twice" do
    byron = plant("Byron Generating Station", facility_type: "power_reactor", status: "operating")
    unit = cite!(plant("Byron 1", parent: byron, status: "operating"), source: @nrc)
    cite!(link(company("Constellation"), "operates", unit), source: @nrc)

    get plant_path(slug: byron.slug)

    assert_select ".nd-factrow", text: /Constellation\s+operates\s+Byron 1\b/
    assert_select ".nd-factrow", text: /Byron Generating Station, Byron 1/, count: 0
  end

  test "a quote that is an NRC table row reads as fields, with the exact row one tap away" do
    list = Source.create!(url: "https://www.nrc.gov/test/reactor-list", source_kind: "nrc_reactor_list")
    row = "Byron 1 | 05000454 | NPF-37 | PWR | 17 miles SW of Rockford, IL | Constellation Energy Generation, LLC | 3"
    byron = plant("Byron Generating Station", facility_type: "power_reactor", status: "operating")
    unit = cite!(plant("Byron 1", parent: byron, status: "operating"), source: list)
    link(company("Constellation"), "operates", unit).evidence.create!(source: list, quote: row, found_by: "human", confidence: 1)

    get plant_path(slug: byron.slug)

    assert_select ".nd-factrow .nd-quote--data" do
      assert_select "p", "Byron 1 · Docket 05000454 · License NPF-37 · PWR · 17 miles SW of Rockford, IL · Constellation Energy Generation, LLC · NRC region 3"
      assert_select "details.nd-quote__row summary", "Show source row"
      assert_select "details.nd-quote__row code", row
    end
  end

  test "unverified companies and links never appear" do
    get plant_path(slug: "plant-vogtle")

    assert_select "body", text: /Ghost Buyer/, count: 0
    assert_select "body", text: /Pending Owner/, count: 0
    assert_select "body", text: /Unit 5/, count: 0
  end

  test "units are listed with their details" do
    get plant_path(slug: "plant-vogtle")

    assert_select "#units-heading small", "2"
    assert_select "tr#unit-unit-4" do
      assert_select "th[scope=row]", "Unit 4"
      assert_select "td[data-label='Reactor type']", "AP1000"
      assert_select "td[data-label='Capacity']", "1,114 MW"
      assert_select "td[data-label='NRC docket']", "05200026"
      assert_select "td[data-label='Sources'] a.nd-src[href='#source-2']"
    end
  end

  test "an ended link isn't shown as current" do
    FacilityRelationship.find_by!(organization: @westinghouse).update!(ended_on: Date.new(2020, 1, 1))
    get plant_path(slug: "plant-vogtle")

    assert_select "body", text: /Westinghouse/, count: 0
  end

    test "a unit's address goes to its row on the site's page" do
    get plant_path(slug: "unit-3")

    assert_redirected_to plant_path(slug: "plant-vogtle", anchor: "unit-unit-3")
    assert_response :moved_permanently
  end

  test "key facts" do
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-overview dd", text: /Waynesboro, GA/
    assert_select ".nd-overview dt", "Owner"
    assert_select ".nd-overview dd a[href='/companies/georgia-power']", "Georgia Power"
    assert_select ".nd-overview dt", "Operator"
    assert_select ".nd-overview dt", "Reactor designer"
    assert_select ".nd-overview dd", text: /\AFission/
    assert_select ".nd-overview dd", text: /\AAP1000/
    assert_select ".nd-overview dd", text: /\A2,228 MW\b/
    assert_select ".nd-overview dt", text: "Power buyer", count: 0
    assert_select ".nd-overview p.nd-overview__sources", text: /\AAbout this plant: sources\s*\d/
    assert_select ".nd-overview__foot", /checked 2026-10-09/
  end

  test "capacity reads MW, explained once in the key facts" do
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-overview dd", text: /2,228 MW.*Net summer capacity, from EIA/m
    assert_select "main", text: /Net summer capacity, from EIA/, count: 1
    assert_select "td[data-label='Capacity']", text: /Net summer/, count: 0
    assert_no_match "MWe", response.body
  end

  test "capacity counts operating units only, and says so when some units are left out" do
    cite!(plant("Unit 1", parent: @vogtle, capacity_mw: 900, status: "decommissioning"), source: @nrc)
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-overview dd", text: /\A2,228 MW\b.*Net summer capacity of operating units, from EIA/m
    assert_select "td[data-label='Capacity']", "900 MW", "the units table still lists every unit"
    assert_select "td[data-label='Status']", "Being decommissioned"
  end

  test "a standalone reactor shows its own capacity only while it's operating" do
    columbia = cite!(plant("Columbia", facility_type: "power_reactor", status: "operating", capacity_mw: 1169), source: @nrc)
    get plant_path(slug: columbia.slug)
    assert_select ".nd-overview dd", text: /\A1,169 MW\b.*Net summer capacity, from EIA/m

    columbia.update!(status: "not_operating")
    get plant_path(slug: columbia.slug)
    assert_select ".nd-overview dt", text: "Capacity", count: 0
  end

  test "a plant with no capacity has no capacity note" do
    cite!(plant("Clinch River", facility_type: "power_reactor", status: "planned"), source: @nrc)
    get plant_path(slug: "clinch-river")

    assert_response :success
    assert_select ".nd-overview dt", text: "Capacity", count: 0
    assert_no_match "Net summer capacity", response.body
  end

  test "sources are numbered once, in reading order" do
    get plant_path(slug: "plant-vogtle")

    assert_select "#sources-heading small", "2"
    assert_select "li#source-1 small", "nrc.gov"
    assert_select "li#source-2 a[href='https://www.georgiapower.com/vogtle-4']", "Vogtle Unit 4 enters commercial operation"
  end

  test "missing must-have fields are listed, not guessed" do
    plant("Bare Site")
    get plant_path(slug: "bare-site")

    %w[Type Status Location Owner].each { |field| assert_select ".nd-gaps li", text: field }
    assert_select ".nd-overview dt", text: "Type", count: 0
  end

  test "a pending site with a verified unit shows the unit but not the site's own details" do
    site = plant("Clinch River", verified: false, facility_type: "power_reactor", city: "Oak Ridge", state: "TN")
    cite!(plant("Clinch River Unit 1", parent: site, verified_at: Time.zone.parse("2026-10-08")))
    get plant_path(slug: "clinch-river")

    assert_response :success
    assert_select "tr#unit-clinch-river-unit-1"
    assert_select "body", text: /Oak Ridge/, count: 0
    assert_select ".nd-gaps li", text: "Location"
    assert_select ".nd-overview__foot", /Site not verified yet\s+units checked 2026-10-08/
    assert_select ".nd-badge--verified", count: 0
  end

  test "a link to a pending site itself isn't shown, only links to its verified units" do
    site = plant("Clinch River", verified: false)
    unit = cite!(plant("Clinch River Unit 1", parent: site))
    cite!(link(company("Site Owner"), "owns", site), link(company("Unit Owner"), "owns", unit))
    get plant_path(slug: "clinch-river")

    assert_select "body", text: /Site Owner/, count: 0
    assert_select ".nd-factrow", text: /Unit Owner\s+owns\s+Clinch River Unit 1\b/
  end

  test "facts without a source aren't shown" do
    site = plant("Quiet Site", facility_type: "power_reactor", city: "Nowhere", state: "OR")
    plant("Quiet Unit", parent: site, reactor_type: "BWR")
    link(company("Quiet Owner"), "owns", site)
    get plant_path(slug: "quiet-site")

    assert_response :success
    assert_select "body", text: /Nowhere|Quiet Unit|BWR|Quiet Owner/, count: 0
    %w[Type Location Owner].each { |field| assert_select ".nd-gaps li", text: field }
  end

  test "a renamed plant's old address moves to its page" do
    @vogtle.update!(slug: "vogtle-site")

    get plant_path(slug: "plant-vogtle")

    assert_redirected_to plant_path(slug: "vogtle-site")
    assert_response :moved_permanently
  end

  test "a hidden plant's old address isn't redirected" do
    hidden = plant("Quiet Site", verified: false)
    hidden.update!(slug: "quiet-site-renamed")

    get plant_path(slug: "quiet-site")

    assert_response :not_found
  end

  test "an unsourced unit's address isn't redirected to a row that isn't there" do
    plant("Unit 9", parent: @vogtle)
    get plant_path(slug: "unit-9")

    assert_response :not_found
  end

  test "a link that hasn't started yet says when it starts" do
    FacilityRelationship.find_by!(organization: @southern).update!(started_on: 1.year.from_now.to_date)
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-factrow", text: /Southern Nuclear\s+operates/ do
      assert_select ".nd-factrow__detail", /\AStarts /
    end
    # The one-line summary doesn't state a scheduled link as current (#246).
    line = "Plant Vogtle: Operating power plant in Waynesboro, Georgia. 2 units, 2,228 MW. Owned by Georgia Power."
    assert_select "meta[property='og:description'][content=?]", line
    assert_select "meta[name='description'][content=?]", line
  end

  test "an unpublished unit or link disappears from the plant page" do
    @unit4.unpublish!(by: "human:test")
    FacilityRelationship.find_by!(organization: @southern).unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")

    assert_select "tr#unit-unit-4", count: 0
    assert_select "body", text: /Southern Nuclear/, count: 0
    assert_select "tr#unit-unit-3"
  end

  test "a missing NRC docket is listed, and a sourced site with no shown fields isn't cited" do
    site = cite!(plant("Blank Site"))
    cite!(link(cite!(company("Blank Owner")), "owns", site))
    get plant_path(slug: "blank-site")

    assert_select ".nd-gaps li", text: "NRC docket"
    assert_select "#sources-heading small", "1"
    assert_select ".nd-factrow a.nd-src[href='#source-1']"
  end

  test "link preview tags" do
    get plant_path(slug: "plant-vogtle")

    assert_select "meta[property='og:title'][content='Plant Vogtle']"
    line = "Plant Vogtle: Operating power plant in Waynesboro, Georgia. 2 units, 2,228 MW. Owned by Georgia Power; operated by Southern Nuclear."
    assert_select "meta[property='og:description'][content=?]", line
    assert_select "meta[name='description'][content=?]", line # the same line for search results (#246)
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/plants/plant-vogtle"
  end

  test "hidden or unknown plants are not found" do
    plant("Pending Only", verified: false)
    Facility.create!(name: "Rejected Station", verification_status: "rejected", verified_by: "human:test")

    %w[pending-only rejected-station nobody].each do |slug|
      get plant_path(slug:)
      assert_response :not_found
    end
  end
end
