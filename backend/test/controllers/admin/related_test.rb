require "test_helper"

# A Record's related items (#201, Design's spec on #166): a plant's units
# and companies, a company's deals and plants, each with its status, the
# claims waiting on it and a menu of actions that come back to its row.
class Admin::RelatedTest < ActionDispatch::IntegrationTest
  VERIFIED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  setup do
    @web = Source.create!(url: "https://www.example.com/related", source_kind: "web_page", domain: "example.com")
    sign_in_as users(:admin)
    @site = sourced(Facility.create!(name: "Plant Vogtle", facility_type: "power_reactor", status: "operating", state: "GA", **VERIFIED))
    @u1 = sourced(Facility.create!(name: "Vogtle 1", parent: @site, reactor_type: "PWR", capacity_mw: 1150, **VERIFIED))
    @u2 = sourced(Facility.create!(name: "Vogtle 2", parent: @site, reactor_type: "PWR", capacity_mw: 1152, **VERIFIED))
    @georgia = sourced(Organization.create!(name: "Georgia Power", **VERIFIED))
    @southern = sourced(Organization.create!(name: "Southern Nuclear", **VERIFIED))
    @owns = sourced(FacilityRelationship.create!(organization: @georgia, facility: @site, relationship_type: "owns", ownership_pct: 45.7, **VERIFIED))
    @operates = sourced(FacilityRelationship.create!(organization: @southern, facility: @u1, relationship_type: "operates", **VERIFIED))
  end

  def sourced(fact) = fact.tap { Evidence.create!(subject: fact, source: @web, quote: "q", found_by: "human") }
  def record(fact, **params) = admin_record_path(type: fact.class.name, id: fact.id, **params)
  def rows(section) = css_select("##{section} tbody tr").map { |tr| tr.css("td").first.text.squish }

  test "a plant shows its units, then its companies, owners first with their share" do
    get record(@site)

    assert_equal [ "Vogtle 1", "Vogtle 2" ], rows("units")
    assert_select "#units tbody tr:first-child", /PWR.*1,150 MW.*Live/m
    assert_equal [ "Georgia Power", "Southern Nuclear" ], rows("companies")
    assert_select "#companies tbody tr:first-child td", /owns\s+· 45.7%/
    assert_select "#companies tbody tr:last-child td", /operates\s+· Vogtle 1/
    assert_select "#companies a[href=?]", record(@georgia, from: "record", section: "companies", row: "FacilityRelationship-#{@owns.id}", back: record(@site)), "Georgia Power"
  end

  test "a company shows its deals and links, then its plants" do
    google = sourced(Organization.create!(name: "Google", **VERIFIED))
    sourced(Relationship.create!(from_organization: google, to_organization: @georgia, relationship_type: "offtake_with", **VERIFIED))

    get record(@georgia)

    assert_select "section.nd-related h2", text: /Deals and links|Plants and sites/, count: 2
    assert_equal [ "Google" ], rows("deals")
    assert_select "#deals td", /offtakes from Georgia Power\s+· Power deal/
    assert_equal [ "Plant Vogtle" ], rows("plants")
    assert_select "#plants td", /owns\s+· Power plant · Operating · GA · 45.7%/
  end

  test "status and claims waiting; removed rows show on request" do
    Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure",
      subject_type: "Facility", subject_id: @u2.id, payload: { "name" => "Vogtle 2" })
    @u1.unpublish!(by: "human:tosin", reason: "Test")

    get record(@site)

    assert_equal [ "Vogtle 2" ], rows("units")
    assert_select "#units tbody tr td", /Live\s+· 1 waiting/
    assert_select "#units a", "Show removed (1)"

    get record(@site, removed: "units")
    assert_equal [ "Vogtle 1", "Vogtle 2" ], rows("units")
    assert_select "#item-Facility-#{@u1.id} td", /Removed/
    assert_select "#item-Facility-#{@u1.id} button", "Put back"
  end

  test "Take off from a row needs a reason, then comes back to the Record at that row" do
    here = "#{record(@site)}#item-FacilityRelationship-#{@owns.id}"

    get record(@site)
    assert_select "#item-FacilityRelationship-#{@owns.id} details.nd-rowmenu summary[aria-label=?]", "Actions for Georgia Power"
    assert_select "#item-FacilityRelationship-#{@owns.id} input[name=reason][required]"

    post admin_fact_unpublish_path(type: "FacilityRelationship", id: @owns.id), params: { reason: "", next: here }
    assert @owns.reload.verified?

    post admin_fact_unpublish_path(type: "FacilityRelationship", id: @owns.id), params: { reason: "Sold its share", next: here }
    assert_response :see_other
    assert_redirected_to here
    assert @owns.reload.unpublished?
    assert_match(/\ATaken off: /, flash[:notice])
  end

  test "Take off from a row's menu comes back with the section's removed rows shown, so the row and Put back are there" do
    get record(@site)
    takeoff_next = css_select("#item-FacilityRelationship-#{@owns.id} form.nd-rowmenu__takeoff input[name=next]").first["value"]
    assert_equal "#{record(@site, removed: 'companies')}#item-FacilityRelationship-#{@owns.id}", takeoff_next

    post admin_fact_unpublish_path(type: "FacilityRelationship", id: @owns.id), params: { reason: "Sold its share", next: takeoff_next }
    assert_redirected_to takeoff_next
    follow_redirect!
    assert_select "#item-FacilityRelationship-#{@owns.id} td", /Removed/
    assert_select "#item-FacilityRelationship-#{@owns.id} button", "Put back"
  end

  test "Edit from a row edits the unit and comes back to its row; a link's ends can't be edited" do
    here = "#{record(@site)}#item-Facility-#{@u1.id}"

    get admin_fact_edit_path(type: "Facility", id: @u1.id, back: record(@site), next: here)
    assert_select "input[name=?]", "values[capacity_mw]"
    patch admin_fact_path(type: "Facility", id: @u1.id), params: { values: { capacity_mw: "1160" }, next: here }
    assert_redirected_to here
    assert_equal 1160, @u1.reload.capacity_mw

    get admin_fact_edit_path(type: "FacilityRelationship", id: @owns.id)
    assert_select "input[name=?]", "values[ownership_pct]"
    assert_select "input[name=?]", "values[organization_id]", 0
    assert_select "input[name=?]", "values[relationship_type]", 0
  end

  test "Decide goes through the item's waiting claims, then back to the Record at its row" do
    claim = ->(state) { Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure", subject_type: "Facility", subject_id: @u2.id, payload: { "name" => "Vogtle 2", "state" => state }) }
    first, second = claim.("GA"), claim.("AL")
    here = "#{record(@site, removed: 'units')}#item-Facility-#{@u2.id}"
    context = { claims: 1, from: "record", section: "units", row: "Facility-#{@u2.id}", back: here }

    get record(@site)
    assert_select "#item-Facility-#{@u2.id} .nd-rowmenu a[href=?]", admin_fact_path(type: "Facility", id: @u2.id, claim: first.id, **context), "Decide"

    get admin_fact_path(type: "Facility", id: @u2.id, claim: first.id, **context)
    assert_select ".nd-itemnav", /1 of 2 waiting/
    following = admin_fact_path(type: "Facility", id: @u2.id, **context.except(:claims), claims: 1, claim: second.id)
    assert_select ".nd-itemnav a[rel=next][href=?]", following

    post reject_admin_candidates_path, params: { candidate_id: first.id, back: here, next: following }
    assert_redirected_to following
    post reject_admin_candidates_path, params: { candidate_id: second.id, back: here }
    assert_redirected_to here
  end

  test "Edit from a row: Live / the Record / the item / Edit" do
    get admin_fact_edit_path(type: "Facility", id: @u1.id, from: "record", section: "units", row: "Facility-#{@u1.id}", back: record(@site), next: "#{record(@site)}#item-Facility-#{@u1.id}")

    assert_equal [ "Live", "Plant Vogtle", "Vogtle 1", "Edit" ], css_select(".nd-crumbs li").map { |li| li.text.squish }
  end

  test "a related row's page: Live / the Record / it, with Previous and Next through its section" do
    live = admin_live_path(tab: "plants")
    parent = record(@site, back: live)
    context = ->(unit) { { from: "record", section: "units", row: "Facility-#{unit.id}", back: parent } }

    get admin_fact_path(type: "Facility", id: @u1.id, **context.(@u1))

    assert_select ".nd-crumbs li a[href=?]", live, "Live"
    assert_select ".nd-crumbs li a[href=?]", parent, "Plant Vogtle"
    assert_select ".nd-crumbs li[aria-current]", "Vogtle 1"
    assert_select ".nd-itemnav", /1 of 2/
    assert_select ".nd-itemnav a[rel=next][href=?]", admin_fact_path(type: "Facility", id: @u2.id, **context.(@u2))

    get record(@georgia, from: "record", section: "companies", row: "FacilityRelationship-#{@owns.id}", back: parent)
    assert_select ".nd-crumbs li a[href=?]", parent, "Plant Vogtle"
    assert_select ".nd-itemnav", /1 of 2/
  end

  test "Live in the crumbs is still the Live list after going Record to Record (Live → plant → company → its row)" do
    live = admin_live_path(tab: "plants", q: "vogtle")
    plant = record(@site, back: live)
    company = record(@georgia, from: "record", section: "companies", row: "FacilityRelationship-#{@owns.id}", back: plant)

    get admin_fact_path(type: "FacilityRelationship", id: @owns.id, from: "record", section: "plants", row: "FacilityRelationship-#{@owns.id}", back: company)

    assert_select ".nd-crumbs li a[href=?]", live, "Live"
    assert_select ".nd-crumbs li a[href=?]", company, "Georgia Power"
  end

  test "a row's link picks its page from its section, without a lookup per row" do
    get record(@site)
    assert_select "#item-Facility-#{@u1.id} td.nd-related__name a[href^=?]", admin_fact_path(type: "Facility", id: @u1.id)

    get record(@georgia)
    assert_select "#plants td.nd-related__name a[href^=?]", record(@site)

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].match?(/FROM "facilities" WHERE "facilities"."id" = .* AND "facilities"."parent_id" IS NULL/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get record(@site) }
    assert_empty queries
  end

  test "Previous and Next keep the section's rows as the Record showed them" do
    @u1.unpublish!(by: "human:tosin", reason: "Test")
    parent = record(@site, removed: "units")

    get parent
    first = css_select("#item-Facility-#{@u1.id} td.nd-related__name a").first["href"]
    assert_equal admin_fact_path(type: "Facility", id: @u1.id, from: "record", section: "units", row: "Facility-#{@u1.id}", back: record(@site), with_removed: 1), first

    get first
    assert_select ".nd-itemnav", /1 of 2/
    following = css_select(".nd-itemnav a[rel=next]").first["href"]
    get following
    assert_select ".nd-itemnav", /2 of 2/
    assert_select ".nd-itemnav a[rel=prev]"
  end

  test "a lapsed recommendation isn't the row's waiting claim; the one the fact page decides is" do
    lapsed = Candidate.create!(source: @web, kind: "facility", quote: "q", status: "matched", ai_recommendation: "recommend_publish",
      ai_source_sha256: "old", subject_type: "Facility", subject_id: @u2.id, payload: { "name" => "Vogtle 2" })
    open = Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure",
      subject_type: "Facility", subject_id: @u2.id, payload: { "name" => "Vogtle 2", "state" => "AL" })
    assert lapsed.id < open.id

    get record(@site)
    assert_select "#item-Facility-#{@u2.id} td", /Live\s+· 1 waiting/
    decide = css_select("#item-Facility-#{@u2.id} .nd-rowmenu a").find { |a| a.text == "Decide" }["href"]
    assert_includes decide, "claim=#{open.id}"

    get decide
    assert_select ".nd-decide button", /Approve/
  end

  test "editing a claim reached through a row's claims goes on to the next claim, then back to the row" do
    claim = ->(state) { Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure", subject_type: "Facility", subject_id: @u2.id, payload: { "name" => "Vogtle 2", "state" => state }) }
    first, second = claim.("GA"), claim.("AL")
    here = "#{record(@site)}#item-Facility-#{@u2.id}"
    context = { claims: 1, from: "record", section: "units", row: "Facility-#{@u2.id}", back: here }
    following = admin_fact_path(type: "Facility", id: @u2.id, **context, claim: second.id)

    get admin_fact_path(type: "Facility", id: @u2.id, claim: first.id, **context)
    edit = css_select("a.nd-decide__edit").first["href"]
    assert_includes Rack::Utils.parse_query(URI.parse(edit).query)["done"], "claim=#{second.id}"

    get edit
    assert_select ".nd-crumbs a", "Back"
    patch admin_candidate_path(first.id, **Rack::Utils.parse_query(URI.parse(edit).query).symbolize_keys), params: { values: { state: "GA" } }
    assert_redirected_to following

    get following
    edit = css_select("a.nd-decide__edit").first["href"]
    assert_equal here, Rack::Utils.parse_query(URI.parse(edit).query)["done"]
    patch admin_candidate_path(second.id, **Rack::Utils.parse_query(URI.parse(edit).query).symbolize_keys), params: { values: { state: "AL" } }
    assert_redirected_to here
  end

  test "rejecting the last claim on a proposed unit comes back to its row, still shown, rejected" do
    proposed = Facility.create!(name: "Vogtle 5", parent: @site)
    claim = Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure",
      subject_type: "Facility", subject_id: proposed.id, proposed_subject: true, payload: { "name" => "Vogtle 5" })

    get record(@site)
    decide = css_select("#item-Facility-#{proposed.id} .nd-rowmenu a").find { |a| a.text == "Decide" }["href"]
    back = Rack::Utils.parse_query(URI.parse(decide).query)["back"]
    assert_equal "#{record(@site, removed: 'units')}#item-Facility-#{proposed.id}", back

    post reject_admin_candidates_path, params: { candidate_id: claim.id, back: }
    assert_redirected_to back
    assert proposed.reload.rejected?, "rejecting the proposal's last claim retires it"
    follow_redirect!
    assert_select "#item-Facility-#{proposed.id} td", /Rejected/
  end

  test "with removed rows shown, a link's words keep them for Previous and Next" do
    @owns.unpublish!(by: "human:tosin", reason: "Test")

    get record(@site, removed: "companies")
    words = css_select("#item-FacilityRelationship-#{@operates.id} td.nd-related__link a").first["href"]
    assert_includes words, "with_removed=1"
  end

  test "a site's EIA plant ID can be corrected on its Record; a link's ends can't" do
    @site.update_columns(eia_plant_id: "649")

    get admin_record_edit_path(type: "Facility", id: @site.id)
    assert_select "input[name=?]", "values[eia_plant_id]"
    patch admin_record_path(type: "Facility", id: @site.id), params: { values: { eia_plant_id: "6051" } }
    assert_equal "6051", @site.reload.eia_plant_id

    get admin_fact_edit_path(type: "FacilityRelationship", id: @owns.id)
    assert_select "input[name=?]", "values[organization_id]", 0
    assert_select "input[name=?]", "values[facility_id]", 0
  end

  test "Live in the crumbs survives any number of Records deep" do
    live = admin_live_path(tab: "plants", q: "vogtle")
    path = record(@site, back: live)
    companies = (1..7).map { |n| sourced(Organization.create!(name: "Hop #{n} Co", **VERIFIED)) }
    companies.each { |company| path = record(company, from: "record", section: "deals", row: "Relationship-0", back: path) }

    get admin_fact_path(type: "FacilityRelationship", id: @owns.id, from: "record", section: "plants", row: "FacilityRelationship-#{@owns.id}", back: path)

    assert_select ".nd-crumbs li a[href=?]", live, "Live"
  end

  test "Take off and Put back on a claim reached through a row's claims keep going through its claims" do
    Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure", subject_type: "Facility", subject_id: @u2.id, payload: { "name" => "Vogtle 2" })
    here = "#{record(@site, removed: 'units')}#item-Facility-#{@u2.id}"
    get admin_fact_path(type: "Facility", id: @u2.id, claims: 1, from: "record", section: "units", row: "Facility-#{@u2.id}", back: here)

    assert_includes css_select("form[action*='unpublish']").first["action"], "claims=1"
  end

  test "Edit on a Record opened from a row keeps the way back to that row's Record" do
    parent = record(@site, back: admin_live_path)
    company = record(@georgia, from: "record", section: "companies", row: "FacilityRelationship-#{@owns.id}", back: parent)

    get company
    assert_select "a.nd-btn[href=?]", admin_record_edit_path(type: "Organization", id: @georgia.id, from: "record", section: "companies",
      row: "FacilityRelationship-#{@owns.id}", back: parent), "Edit"
  end
end
