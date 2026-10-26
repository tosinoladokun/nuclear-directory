require "test_helper"
require_relative "../support/directory_builders"

class DirectoryTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    vendor = role("reactor_vendor")
    @kairos = company("Kairos Power", city: "Alameda", state: "CA", roles: [ vendor ],
      description: "Develops salt-cooled reactors.")
    @oklo = company("Oklo", roles: [ vendor ])
    cite!(@kairos, @oklo, company("Pending Reactors", roles: [ vendor ], verified: false))
    plant("Plant Vogtle", state: "GA", facility_type: "power_reactor", status: "operating")
  end

  test "the old fusion category moves for good to the fusion tag page, keeping filters (#281)" do
    get companies_path(category: "fusion", state: "CA", sort: "connections")

    assert_response :moved_permanently
    assert_redirected_to companies_url(state: "CA", sort: "connections", tag: "fusion")
  end

  test "?role= narrows the Developers list to reactor designers or project developers; the list shows no role tags and no filter UI" do
    designer = Role.find_by!(key: "reactor_vendor")
    developer = role("project_developer")
    both = cite!(company("Both Roles Inc", roles: [ designer, developer ]))
    builder = cite!(company("Blue Builder Energy", roles: [ developer ]))
    get companies_path(category: "reactor-developers")

    assert_response :success
    assert_select "nav[aria-label=Role]", 0, "no role filter in the page (the ?role= param still works)"
    assert_select ".nd-line .nd-tag", 0, "the role is shown on the company page, not in the list"

    get companies_path(category: "reactor-developers", role: "project_developer")
    assert_select "a.nd-line", 2
    assert_select "a[href='/companies/#{builder.slug}']"
    assert_select "a[href='/companies/kairos-power']", 0
    assert_select "meta[name=robots][content=noindex]"
    assert_select "form.nd-filters input[type=hidden][name=role][value=project_developer]"

    get companies_path(category: "reactor-developers", role: "reactor_vendor")
    assert_select "a[href='/companies/#{builder.slug}']", 0
    assert_select "a[href='/companies/kairos-power']"

    get companies_path(category: "reactor-developers", role: "utility")
    assert_select "a.nd-line", 4
  end

  test "a role no source backs does not put the company under that role" do
    designer = Role.find_by!(key: "reactor_vendor")
    developer = role("project_developer")
    half = cite!(company("Half Sourced Holdings", roles: [ designer ]))
    unsourced = OrganizationRole.create!(organization: half, role: developer, verification_status: "verified", verified_by: "human:tosin", confidence: 1)
    assert_empty unsourced.evidence

    get companies_path(category: "reactor-developers", role: "project_developer")
    assert_select "a[href='/companies/#{half.slug}']", 0
  end

  test "only the Developers list has role chips and a role filter" do
    get companies_path(category: "fuel", role: "reactor_vendor")
    assert_select "nav[aria-label=Role]", 0
    get companies_path
    assert_select ".nd-line .nd-tag", 0
    assert_select "nav[aria-label=Role]", 0
  end

  test "a tag page lists the companies with that tag, under its own title and address" do
    cite!(company("Helion", techs: [ technology("fusion", "Fusion") ]))
    get companies_path(tag: "fusion")

    assert_response :success
    assert_select "title", "Fusion energy companies in the US · Nuclear Directory"
    assert_select "h1", /Fusion/
    assert_select ".nd-pagehead__count", "1 company"
    assert_select "a.nd-line[href='/companies/helion']"
    assert_select "a.nd-line[href='/companies/kairos-power']", count: 0
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/companies?tag=fusion", 1
    assert_select "form.nd-filters input[type=hidden][name=tag][value=fusion]"
  end

  test "a company in no bucket still lists, turns up in search and has its page" do
    cite!(company("NextEra Energy", description: "Utility holding company."))
    nextera = Organization.find_by!(name: "NextEra Energy")
    assert_empty Bucket.for(nextera)

    get companies_path
    assert_select "a.nd-line[href='/companies/#{nextera.slug}']"

    get companies_path(q: "NextEra")
    assert_select "a.nd-line[href='/companies/#{nextera.slug}']"

    get company_path(slug: nextera.slug)
    assert_response :success
    assert_select ".nd-overview dt", text: "Type", count: 0
    assert_select ".nd-crumbs a", count: 0
  end

  test "a pending site's row shows its name and verified units, not its own type or place" do
    site = Facility.create!(name: "Quiet Station", verification_status: "pending", facility_type: "power_reactor", status: "planned", city: "Nowhere", state: "OR")
    Facility.create!(name: "Quiet Unit 1", parent: site, verification_status: "verified", verified_by: "human:test", capacity_mw: 300, status: "operating")
    get companies_path(category: "plants")

    assert_select ".nd-line", text: /Quiet Station/ do
      assert_select ".nd-line__what", /1 operating unit/, "the pending site's own status isn't shown, so the unit's is"
      assert_select ".nd-line__cap", "300 MW"
      assert_select ".nd-st", count: 0
    end
    assert_select "body", text: /Nowhere|Planned/, count: 0
  end

  test "the list, a category, and searches or filters within them each name their canonical address" do
    get companies_path
    assert_select "link[rel=canonical][href='http://www.example.com/companies']", 1

    get companies_path(category: "reactor-developers", state: "CA")
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/companies?category=reactor-developers", 1

    get companies_path(q: "kairos")
    assert_select "link[rel=canonical][href='http://www.example.com/companies']", 1
  end

  test "a category lists its verified companies" do
    get companies_path(category: "reactor-developers")

    assert_response :success
    assert_select "title", "Nuclear reactor and project developers in the US · Nuclear Directory"
    assert_select "h1", /Developers/
    assert_select ".nd-pagehead__count", "2 companies"
    assert_select ".nd-idx a[aria-current=page]", /Developers/
    assert_select ".nd-chips a.nd-chip[aria-current=page]", /Developers/, "phones: the same categories as a scrolling row"
    assert_select "a.nd-line[href='/companies/kairos-power'] .nd-line__what", /Reactor designer/, "no short description yet: role · specialty"
    assert_select "a.nd-line[href='/companies/kairos-power'] .nd-line__end", "Alameda, CA"
    assert_select "a.nd-line[href='/companies/kairos-power'] .nd-mono, a.nd-line[href='/companies/kairos-power'] .nd-tag", 0, "no mark, no tags on the row"
    assert_select "a.nd-line", text: /Pending Reactors/, count: 0
  end

  test "a category narrows to one of its roles, with its canonical address the whole category" do
    get companies_path(category: "reactor-developers", role: "project_developer")
    assert_response :success
    assert_select "a.nd-line[href='/companies/kairos-power']", 0
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/companies?category=reactor-developers", 1
    assert_select "meta[name=robots][content=noindex]"

    get companies_path(category: "reactor-developers", role: "reactor_vendor")
    assert_select "a.nd-line[href='/companies/kairos-power']"
    assert_select "form.nd-filters input[type=hidden][name=role][value=reactor_vendor]"

    get companies_path(category: "reactor-developers", role: "project_developer", format: :json)
    project = response.parsed_body["count"]
    get companies_path(category: "reactor-developers", format: :json)
    assert_operator project, :<, response.parsed_body["count"], "the filter sheet's count keeps the role"
  end

  test "a company without a description or HQ still lists" do
    get companies_path(category: "reactor-developers")

    assert_select "a.nd-line[href='/companies/oklo']"
    assert_select "a.nd-line[href='/companies/oklo'] .nd-line__end", ""
  end

  test "search results group companies and power plants" do
    company("Vogtle Services Co", roles: [ role("reactor_services") ])
    get companies_path(q: "vogtle")

    assert_select "h1", /Results for “vogtle”/
    assert_select "#companies-heading", "Companies"
    assert_select "#plants-heading", "Plants and sites"
    assert_select "a.nd-line[href='/plants/plant-vogtle']", /Power plant/
    assert_select "a.nd-line[href='/plants/plant-vogtle'] .nd-st", /Operating/
  end

  test "the search field keeps the query" do
    get companies_path(q: "kairos")

    assert_select ".nd-sitebar input[name=q][value=kairos]"
    assert_select "form.nd-filters input[type=hidden][name=q][value=kairos]"
  end

  test "no results offers to clear the search" do
    get companies_path(category: "reactor-developers", q: "molten salt pump")

    assert_select ".nd-notice", /No results for “molten salt pump” in Developers./
    assert_select ".nd-notice a[href=?]", "/companies?category=reactor-developers", text: "Clear search"
  end

  test "clearing the search keeps the other filters" do
    get companies_path(category: "reactor-developers", q: "nothing like this", state: "CA", sort: "connections")

    assert_select ".nd-notice a[href=?]", "/companies?category=reactor-developers&sort=connections&state=CA", text: "Clear search"

    get companies_path(category: "reactor-developers", q: "nothing like this", role: "project_developer")
    assert_select ".nd-notice a[href=?]", "/companies?category=reactor-developers&role=project_developer", text: "Clear search"
  end

  test "search and filtered lists aren't indexed; plain lists and categories are" do
    [ companies_path(q: "kairos"), companies_path(state: "CA"), companies_path(category: "reactor-developers", state: "CA") ].each do |path|
      get path
      assert_select "meta[name=robots][content=noindex]", 1, "#{path} should be noindex"
    end

    [ companies_path, companies_path(category: "reactor-developers") ].each do |path|
      get path
      assert_select "meta[name=robots]", 0, "#{path} should be indexable"
      assert_select "meta[name=description]"
    end
  end

  test "filters that match nothing offer to clear them" do
    company("Constellation", state: "MD")
    get companies_path(category: "reactor-developers", state: "MD")

    assert_select ".nd-notice", /Nothing matches these filters./
    assert_select ".nd-notice a", "Clear filters"
  end

  test "plants and sites show a technology filter without coolant types" do
    get companies_path(category: "plants")

    assert_select "select[name=technology]"
    assert_select "select[name=technology] option", text: /coolant/, count: 0
    assert_select "select[name=state]"
    assert_select ".nd-pagehead__count", "1 plant or site"
  end

  test "search results are grouped even when only one kind matches" do
    get companies_path(q: "kairos")

    assert_select "#companies-heading", "Companies"
    assert_select "#plants-heading", count: 0
  end

  # Path data of the site icons, to tell which one a ring holds. All three
  # power plant glyphs share a cooling tower; the reactor building tells them
  # apart: a dome (PWR), a box (BWR), a low turbine hall (type unknown).
  PWR_ICON = "M13 20v-4a4 4 0 0 1 8 0v4"
  BWR_ICON = "M13 20v-8h8v8"
  PLANT_ICON = "M12 20v-5h9v5"

  test "a pending site whose own type isn't public keeps the plain icon, whatever its units' reactor types" do
    site = plant("Quiet Research Site", verified: false, facility_type: "research_reactor")
    cite!(plant("Quiet Research Site Reactor", parent: site, reactor_type: "TRIGA"))
    get companies_path(category: "plants")

    assert_includes css_select("a[href='/plants/quiet-research-site'] .nd-line__mark").to_s, PLANT_ICON, "site-plant"
  end

  test "an unsourced site's own status doesn't pick its icon, in the directory or instant search" do
    plant("Quiet Old Station", facility_type: "power_reactor", status: "decommissioning") # verified, no source
    waste = "M5 21h14M7 21V6h10v15"

    [ companies_path(category: "plants"), search_path(q: "quiet old") ].each do |path|
      get path
      ring = css_select("a[href='/plants/quiet-old-station'] .nd-line__mark, a[href='/plants/quiet-old-station'] .nd-ring").to_s
      assert_includes ring, "<svg", path
      assert_not_includes ring, waste, path
    end
  end

  test "a site's icon uses only reactor types its page shows: sourced site, sourced units (#281)" do
    sourced = cite!(plant("Sourced Station", facility_type: "power_reactor", status: "operating", reactor_type: "PWR"))
    plant("Sourced Station Unit 9", parent: sourced, reactor_type: "BWR", status: "operating") # verified, no source
    plant("Quiet Station", facility_type: "power_reactor", status: "operating", reactor_type: "BWR") # verified, no source

    [ companies_path(category: "plants"), search_path(q: "station") ].each do |path|
      get path
      sourced_ring = css_select("a[href='/plants/sourced-station'] .nd-line__mark, a[href='/plants/sourced-station'] .nd-ring").to_s
      quiet_ring = css_select("a[href='/plants/quiet-station'] .nd-line__mark, a[href='/plants/quiet-station'] .nd-ring").to_s

      assert_includes sourced_ring, PWR_ICON, path
      assert_not_includes sourced_ring, BWR_ICON, "#{path}: an unsourced unit doesn't change it"
      assert_includes quiet_ring, "<svg", path
      assert_not_includes quiet_ring, BWR_ICON, "#{path}: an unsourced site's own reactor type isn't used"
    end
  end

  test "a site row shows its verified units and their operating units' capacity" do
    vogtle = Facility.find_by!(name: "Plant Vogtle")
    plant("Vogtle Unit 3", parent: vogtle, capacity_mw: 1117, status: "operating")
    plant("Vogtle Unit 4", parent: vogtle, capacity_mw: 1117.5, status: "operating")
    plant("Vogtle Unit 5", parent: vogtle, capacity_mw: 999, status: "operating", verified: false)
    get companies_path(category: "plants")

    assert_select "a.nd-line[href='/plants/plant-vogtle'] .nd-line__what", /Power plant · 2 units/
    assert_select "a.nd-line[href='/plants/plant-vogtle'] .nd-line__cap", "2,234.5 MW"

    plant("Vogtle Unit 1", parent: vogtle, capacity_mw: 500, status: "decommissioning")
    get companies_path(category: "plants")

    assert_select "a.nd-line[href='/plants/plant-vogtle'] .nd-line__what", /Power plant · 2 operating units, 1 being decommissioned/
    assert_select "a.nd-line[href='/plants/plant-vogtle'] .nd-line__cap", "2,234.5 MW", "capacity counts operating units only"
  end

  test "an unknown filter value is ignored, not applied behind an Any control" do
    get companies_path(category: "reactor-developers", state: "ZZ")

    assert_select ".nd-pagehead__count", "2 companies"
    assert_select "select[name=state] option[selected]", count: 0
  end

  test "the page has one main landmark, after the site header" do
    get companies_path

    assert_select "main", 1
    assert_select "header.nd-sitebar + main"
  end

  test "filters work without JavaScript" do
    get companies_path(category: "reactor-developers")

    assert_select "form.nd-filters[action='/companies'][method=get]"
    assert_select "form.nd-filters input[type=hidden][name=category][value=reactor-developers]"
    assert_select "form.nd-filters button[type=submit]", "Apply filters"
  end

  test "on phones the filters open in a sheet that counts the results before applying" do
    get companies_path(category: "reactor-developers", state: "CA")

    assert_select ".nd-filterwrap[data-controller=filter-sheet][data-filter-sheet-count-url-value='/companies.json'][data-action='turbo:before-cache@document->filter-sheet#close']" do
      assert_select "button.nd-filterwrap__open[popovertarget=filter-sheet][popovertargetaction=show][data-action='filter-sheet#open']", /Filters\s+\(1\)/
      assert_select "dialog.nd-filtersheet--modal[aria-labelledby=filters-title][data-action='cancel->filter-sheet#close close->filter-sheet#closed']:empty"
      assert_select "#filter-sheet.nd-filtersheet[popover][data-action='toggle->filter-sheet#toggled']" do
        assert_select "form.nd-filters[data-action='change->filter-sheet#count']"
        assert_select "button[popovertarget=filter-sheet][popovertargetaction=hide][data-action='filter-sheet#close']", "Close filters"
        assert_select "p.sr-only[role=status][data-filter-sheet-target=status]"
      end
    end
  end

  test "the count behind \"Show N results\" matches the list and isn't counted as a search" do
    get companies_path(category: "reactor-developers", format: :json)
    assert_equal({ "count" => 2 }, response.parsed_body)

    get companies_path(category: "reactor-developers", state: "CA", format: :json)
    assert_equal({ "count" => 1 }, response.parsed_body)
  end

  test "a tag we don't have searches its words instead of listing every company" do
    get companies_path(tag: "smr", state: "TX")
    assert_redirected_to companies_url(q: "SMR", state: "TX")
    assert_equal 301, response.status
    get companies_path(tag: "molten-salt")
    assert_redirected_to companies_url(q: "molten salt")
    get companies_path(tag: "fusion")
    assert_response :success
  end

  test "the list page: the category index with counts, the page head, a white panel with a visual header row, one quiet line (#560)" do
    get companies_path(category: "reactor-developers")

    assert_select "nav.nd-idx--list[aria-label=Categories]" do
      assert_select "a", text: /All companies/
      assert_select "a[aria-current=page]", 1
      assert_select "a[aria-current=page]", /Developers\s*2/
    end
    assert_select ".nd-pagehead .nd-pagehead__square svg"
    assert_select ".nd-pagehead__about", /Companies designing reactors/
    assert_select "ul.nd-lines li.nd-lines__head[aria-hidden=true]", 1
    assert_select ".nd-line__end", /Alameda, CA/
    assert_select "ul.nd-lines .nd-num", 0, "no connection count on the row"
    assert_select "nav.nd-quiet", /Missing a company\?/
    assert_select "nav.nd-quiet a[href^='/corrections/new']", /Report a correction/
    get companies_path(category: "plants")
    assert_select "nav.nd-quiet", /Missing a plant\?/
  end

  test "a tag page and All companies mark the right index entry, and a tag page has no head square" do
    get companies_path
    assert_select "nav.nd-idx a[aria-current=page]", /All companies/

    get companies_path(tag: "fusion")
    assert_select "nav.nd-idx a[aria-current=page]", 0
    assert_select ".nd-pagehead__square", 0
  end

  test "a written short description is the row's middle column, with the location helper's place" do
    kairos = Organization.find_by!(slug: "kairos-power")
    kairos.update!(short_description: "Fluoride salt-cooled reactors")
    kairos.update!(hq_city: "Courbevoie", hq_state: nil, country_code: "FR")
    get companies_path(category: "reactor-developers")

    assert_select "a.nd-line[href='/companies/kairos-power']" do
      assert_select ".nd-line__what", "Fluoride salt-cooled reactors"
      assert_select ".nd-line__end", "Courbevoie, France"
    end
  end
end
