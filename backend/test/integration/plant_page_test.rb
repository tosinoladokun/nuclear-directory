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

  test "schema.org JSON-LD describes the site as a Place with its facts and sources (#185)" do
    get plant_path(slug: "plant-vogtle")

    graph = JSON.parse(css_select("script[type='application/ld+json']").first.text).fetch("@graph")
    page, place = graph
    assert_equal "http://www.example.com/plants/plant-vogtle", page["url"]
    assert_equal "2026-10-09", page["dateModified"]
    assert_equal [ "Place", "Plant Vogtle" ], place.values_at("@type", "name")
    assert_equal "Waynesboro", place.dig("address", "addressLocality")
    props = place["additionalProperty"].to_h { |property| [ property["name"], property["value"] ] }
    assert_equal "Operating", props["Status"]
    assert_equal({ "@type" => "QuantitativeValue", "value" => 2228.0, "unitText" => "MW" }, props["Capacity"])
    assert_includes page["citation"].map { |c| c["url"] }, "https://www.nrc.gov/vogtle"
    assert_equal page["citation"].size, css_select("ol.nd-sources li").size
  end

  test "a public plant's page shows its facts" do
    get plant_path(slug: "plant-vogtle")

    assert_response :success
    assert_select "title", "Plant Vogtle, Waynesboro, GA: owners and operator · Nuclear Directory"
    assert_select "main", 1
    assert_select "h1.nd-pagehead__name", "Plant Vogtle"
    assert_select ".nd-pagehead__tags .nd-tag", "Power plant"
    assert_select ".nd-pagehead__tags .nd-tag", "AP1000"
    assert_select ".nd-plantstatus .nd-st--filled", /Operating/
    assert_select ".nd-plantstatus", /2 units/
    assert_select ".nd-crumbs a[href=?]", "/companies?category=plants", text: "Plants and sites"
  end

  test "the owner and operator sentence is built from sourced current links only, each name a link" do
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-sentence--wide", "Owned by Georgia Power. Operated by Southern Nuclear, a different company."
    assert_select ".nd-sentence--wide a[href='/companies/georgia-power']", "Georgia Power"
    assert_select ".nd-sentence--wide a[href='/companies/southern-nuclear']", "Southern Nuclear"

    cite!(link(@southern, "owns", @vogtle))
    cite!(link(company("Dalton Utilities"), "owns", @vogtle))
    cite!(link(company("MEAG Power"), "owns", @vogtle))
    get plant_path(slug: "plant-vogtle")
    assert_select ".nd-sentence--wide", "Owned by Dalton Utilities, Georgia Power, MEAG Power and Southern Nuclear. Operated by Southern Nuclear."
    assert_select ".nd-sentence--narrow", "Owned by Dalton Utilities, Georgia Power and 2 others. Operated by Southern Nuclear.", "phones: the first two owners, then the count"
  end

  test "the same company owning and operating reads as one half-sentence; one half known; neither known" do
    cite!(link(@southern, "owns", @vogtle))
    FacilityRelationship.find_by!(organization: @georgia).unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")
    assert_select ".nd-sentence--wide", "Owned and operated by Southern Nuclear."

    FacilityRelationship.find_by!(organization: @southern, relationship_type: "owns").unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")
    assert_select ".nd-sentence--wide", "Operated by Southern Nuclear."

    FacilityRelationship.find_by!(organization: @southern, relationship_type: "operates").unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")
    assert_select ".nd-sentence", 0, "never 'owner unknown'"
    assert_select ".nd-company__head", text: /unknown/i, count: 0
  end

  test "owners and operator: one row per company, the units it covers, the stated share as a bar, sources" do
    get plant_path(slug: "plant-vogtle")

    assert_select "#parties-heading .nd-sechead__count", "3"
    assert_select ".nd-partygroup .nd-label", text: /Owners/
    assert_select ".nd-crow", text: /Georgia Power/ do
      assert_select ".nd-crow__what", "unit 3"
      assert_select ".nd-crow__share[aria-label='45.7% share']" do
        assert_select ".nd-share__fill[style*='45.7%']"
        assert_select ".nd-crow__pct", /45\.7%/
      end
      assert_select "a.nd-mark[href='#source-2']"
      assert_select ".nd-crow__more[hidden]" do
        assert_select "p", /Co-owned with Oglethorpe Power and MEAG Power\./
        assert_select ".nd-quote", "“the project's co-owners”"
        assert_select "a[href='/companies/georgia-power']", "Open Georgia Power"
      end
    end
    assert_select ".nd-crow", text: /Southern Nuclear/ do
      assert_select ".nd-share", 0, "no stated share: no bar and no percentage"
    end
    assert_select ".nd-crow", text: /Westinghouse Nuclear/
    assert_select "a", text: "Report a correction", count: 1
  end

  test "inside a labelled group a row has no verb; one decimal on every share when any has one" do
    other = cite!(link(company("Oglethorpe Power Corporation"), "owns", @unit4))
    other.update!(ownership_pct: 30)
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-partygroup .nd-crow__rest", 0, "the group label says what they do"
    assert_select ".nd-crow__pct", text: /45\.7%/
    assert_select ".nd-crow__pct", text: /30\.0%/, count: 1
  end

  test "the deals group keeps its verb, which has no group label" do
    buyer = cite!(link(company("Power Buyer Co"), "offtakes_from", @vogtle))
    buyer.update!(description: "Signed: 100 MW.")
    get plant_path(slug: "plant-vogtle")

    assert_select "#deals .nd-crow__rest", text: /buys power/
  end

  test "the section and its index entry are named after the groups it has" do
    FacilityRelationship.find_by!(organization: @southern).unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")

    assert_select "#parties-heading", /\AOwners and developer/, "named after every group it holds, the reactor developer too"
    assert_select "#parties-heading", text: /operator/i, count: 0
    assert_select "nav.nd-idx a[href='#parties']", /Owners/
    assert_select "nav.nd-idx a[href='#parties']", text: /Owners and ope/, count: 0

    FacilityRelationship.find_by!(organization: @georgia).unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")
    assert_select "#parties-heading", /Reactor developer/
  end

  test "a link to the site that states its units shows them on the row, stated and never inferred" do
    site_link = cite!(link(company("Site Level Co"), "owns", @vogtle))
    site_link.update!(description: "Units 3 and 4: 22.7% share.", ownership_pct: 22.7)
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-crow", text: /Site Level Co/ do
      assert_select ".nd-crow__what", "units 3 and 4"
    end
    other = cite!(link(company("Silent Co"), "owns", @vogtle))
    get plant_path(slug: "plant-vogtle")
    assert_select ".nd-crow", text: /Silent Co/ do
      assert_select ".nd-crow__what", 0
    end
  end

  test "an opened row shows its source as plain text: no boxed number" do
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-crow__more a.nd-src--plain", "georgiapower.com", "the domain only: no date, no number, no confidence"
    assert_select ".nd-crow__more .nd-src sup", 0
    assert_select ".nd-crow__more .nd-conf", 0
    assert_select ".nd-crow__more", text: /checked/, count: 0
  end

  test "a share shows only when every folded link states the same one" do
    unit4 = @unit4
    cite!(link(@georgia, "owns", unit4)) # no stated share on Unit 4
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-crow", text: /Georgia Power/ do
      assert_select ".nd-crow__what", "units 3 and 4"
      assert_select ".nd-share", 0, "a 45.7% bar would claim a share for Unit 4 that no source states"
    end
  end

  test "a folded row keeps each link's own description and start date, and the exact source row" do
    FacilityRelationship.find_by!(organization: @georgia).update!(started_on: Date.new(2020, 1, 1))
    later = cite!(link(@georgia, "owns", @unit4))
    later.update!(description: "Conditional on state approval.", started_on: 2.years.from_now.to_date)
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-crow", text: /Georgia Power/ do
      assert_select ".nd-crow__more p", text: /Unit 3:.*Co-owned with Oglethorpe Power and MEAG Power\. Since January 2020/
      assert_select ".nd-crow__more p", text: /Unit 4:.*Conditional on state approval\. Starts /
    end
  end

  test "a row shows the stored source row behind a dataset quote" do
    list = Source.create!(url: "https://www.nrc.gov/test/reactor-list", source_kind: "nrc_reactor_list")
    row = "Byron 1 | 05000454 | NPF-37 | PWR | 17 miles SW of Rockford, IL | Constellation Energy Generation, LLC | 3"
    byron = plant("Byron Generating Station", facility_type: "power_reactor", status: "operating")
    unit = cite!(plant("Byron 1", parent: byron, status: "operating"), source: list)
    link(company("Constellation"), "operates", unit).evidence.create!(source: list, quote: row, found_by: "human", confidence: 1)
    get plant_path(slug: byron.slug)

    assert_select ".nd-crow__more .nd-quote--data details.nd-quote__row" do
      assert_select "summary", "Show source row"
      assert_select "code", row
    end
  end

  test "a company with several unit links is one row naming the units it covers" do
    cite!(link(@southern, "operates", @unit3))
    cite!(link(@southern, "operates", @unit4))
    FacilityRelationship.find_by!(organization: @southern, facility: @vogtle).unpublish!(by: "human:test")
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-crow", text: /Southern Nuclear/, count: 1
    assert_select ".nd-crow", text: /Southern Nuclear/ do
      assert_select ".nd-crow__what", "units 3 and 4"
    end
  end

  test "a unit that carries the plant's name isn't named twice" do
    byron = plant("Byron Generating Station", facility_type: "power_reactor", status: "operating")
    unit = cite!(plant("Byron 1", parent: byron, status: "operating"), source: @nrc)
    cite!(link(company("Constellation"), "operates", unit), source: @nrc)

    get plant_path(slug: byron.slug)

    assert_select ".nd-crow", text: /Constellation/ do
      assert_select ".nd-crow__what", "unit 1"
    end
    assert_select "body", text: /Byron Generating Station, Byron 1/, count: 0
  end

  test "a quote that is an NRC table row reads as fields, with the exact row one tap away" do
    list = Source.create!(url: "https://www.nrc.gov/test/reactor-list", source_kind: "nrc_reactor_list")
    row = "Byron 1 | 05000454 | NPF-37 | PWR | 17 miles SW of Rockford, IL | Constellation Energy Generation, LLC | 3"
    byron = plant("Byron Generating Station", facility_type: "power_reactor", status: "operating")
    unit = cite!(plant("Byron 1", parent: byron, status: "operating"), source: list)
    link(company("Constellation"), "operates", unit).evidence.create!(source: list, quote: row, found_by: "human", confidence: 1)

    get plant_path(slug: byron.slug)

    assert_select ".nd-crow__more .nd-quote--data p", "Byron 1 · Docket 05000454 · License NPF-37 · PWR · 17 miles SW of Rockford, IL · Constellation Energy Generation, LLC · NRC region 3"
  end

  test "unverified companies and links never appear" do
    get plant_path(slug: "plant-vogtle")

    assert_select "body", text: /Ghost Buyer/, count: 0
    assert_select "body", text: /Pending Owner/, count: 0
    assert_select "body", text: /Unit 5/, count: 0
  end

  test "units are listed with their details: the status as a mark and words, the sources as a mark" do
    get plant_path(slug: "plant-vogtle")

    assert_select "#units-heading .nd-sechead__count", "2"
    assert_select "tr#unit-unit-4" do
      assert_select "th[scope=row]", "Unit 4"
      assert_select "td[data-col=reactor]", "AP1000"
      assert_select "td[data-col=capacity]", "1,114 MW"
      assert_select "td[data-col=nrc-docket]", "05200026"
      assert_select "td[data-col=status] .nd-st--filled", /Operating/
      assert_select "td[data-col=sources] a.nd-mark[href='#source-2']"
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

  test "key facts: value first, status with its units, capacity with its basis, no checked date or verified badge" do
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-glance dt", text: /\AStatus/
    assert_select ".nd-glance dd .nd-st", /Operating/
    assert_select ".nd-glance dt .nd-glance__note", "2 units"
    assert_select ".nd-glance dd", "Waynesboro, GA"
    assert_select ".nd-glance dt", "Operator"
    assert_select ".nd-glance dd a[href='/companies/southern-nuclear']", "Southern Nuclear"
    assert_select ".nd-glance dt", text: /Reactor developer/
    assert_select ".nd-glance dd", "AP1000"
    assert_select ".nd-glance dd", /\A2,228 MW/
    assert_select ".nd-glance dt", text: /Capacity.*net summer \(EIA\)/
    assert_select ".nd-glance dt", text: "NRC docket", count: 0 # several units: each one's docket is in the table
    assert_select ".nd-glance .nd-src, .nd-glance .nd-badge", 0
    assert_select ".nd-glance", text: /checked/, count: 0
  end

  test "capacity reads MW, with its basis once in the key facts" do
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-glance dd", text: /2,228 MW/
    assert_select "main", text: /net summer \(EIA\)/, count: 1
    assert_no_match "MWe", response.body
  end

  test "capacity counts operating units only, and says so when some units are left out" do
    cite!(plant("Unit 1", parent: @vogtle, capacity_mw: 900, status: "decommissioning"), source: @nrc)
    get plant_path(slug: "plant-vogtle")

    assert_select ".nd-glance dd", text: /\A2,228 MW\b/
    assert_select ".nd-glance dt", text: /operating units, net summer \(EIA\)/
    assert_select ".nd-plantstatus", /2 of 3 units/
    assert_select "td[data-col=capacity]", "900 MW", "the units table still lists every unit"
    assert_select "tr#unit-unit-1 td[data-col=status]", /Being decommissioned/
  end

  test "a standalone reactor shows its own capacity only while it's operating" do
    columbia = cite!(plant("Columbia", facility_type: "power_reactor", status: "operating", capacity_mw: 1169), source: @nrc)
    get plant_path(slug: columbia.slug)
    assert_select ".nd-glance dd", text: /\A1,169 MW\b/

    columbia.update!(status: "not_operating")
    get plant_path(slug: columbia.slug)
    assert_select ".nd-glance dt", text: /\ACapacity/, count: 0
  end

  test "a plant with no capacity has no capacity note" do
    cite!(plant("Clinch River", facility_type: "power_reactor", status: "planned"), source: @nrc)
    get plant_path(slug: "clinch-river")

    assert_response :success
    assert_select ".nd-glance dt", text: /\ACapacity/, count: 0
    assert_no_match "net summer", response.body
  end

  test "sources are numbered once, in reading order" do
    get plant_path(slug: "plant-vogtle")

    assert_select "li#source-1 small", "nrc.gov"
    assert_select "li#source-2 a[href='https://www.georgiapower.com/vogtle-4']", "Vogtle Unit 4 enters commercial operation"
  end

  test "a missing field is left out, with no list of what's missing" do
    plant("Bare Site")
    get plant_path(slug: "bare-site")

    assert_response :success
    assert_select ".nd-gaps", 0
    %w[Type Status Location].each { |field| assert_select ".nd-glance dt", text: field, count: 0 }
  end

  test "a pending site with a verified unit shows the unit but not the site's own details" do
    site = plant("Clinch River", verified: false, facility_type: "power_reactor", city: "Oak Ridge", state: "TN")
    cite!(plant("Clinch River Unit 1", parent: site, verified_at: Time.zone.parse("2026-10-08")))
    get plant_path(slug: "clinch-river")

    assert_response :success
    assert_select "tr#unit-clinch-river-unit-1"
    assert_select "body", text: /Oak Ridge/, count: 0
    assert_select ".nd-glance dt", text: "Location", count: 0
    assert_select ".nd-badge--verified", count: 0
  end

  test "a link to a pending site itself isn't shown, only links to its verified units" do
    site = plant("Clinch River", verified: false)
    unit = cite!(plant("Clinch River Unit 1", parent: site))
    cite!(link(company("Site Owner"), "owns", site), link(company("Unit Owner"), "owns", unit))
    get plant_path(slug: "clinch-river")

    assert_select "body", text: /Site Owner/, count: 0
    assert_select ".nd-crow", text: /Unit Owner/ do
      assert_select ".nd-crow__what", "unit 1"
    end
  end

  test "facts without a source aren't shown" do
    site = plant("Quiet Site", facility_type: "power_reactor", city: "Nowhere", state: "OR")
    plant("Quiet Unit", parent: site, reactor_type: "BWR")
    link(company("Quiet Owner"), "owns", site)
    get plant_path(slug: "quiet-site")

    assert_response :success
    assert_select "body", text: /Nowhere|Quiet Unit|BWR|Quiet Owner/, count: 0
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

    assert_select ".nd-crow", text: /Southern Nuclear/ do
      assert_select ".nd-crow__more p", /Starts /
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

    assert_select "nav.nd-idx a[href='#sources']", /Sources\s*1/
    assert_select ".nd-crow a.nd-mark[href='#source-1']"
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
