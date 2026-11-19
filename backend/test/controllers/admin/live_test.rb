require "test_helper"

# Live and Record (#201 part 2): every record with Data Quality's tags,
# chips that narrow the list and count what they'd show, and a company's or
# plant's Record with its public view and actions.
class Admin::LiveTest < ActionDispatch::IntegrationTest
  VERIFIED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  setup do
    @web = Source.create!(url: "https://www.example.com/live", source_kind: "web_page", domain: "example.com")
    sign_in_as users(:admin)
  end

  def company(name, **attributes) = Organization.create!(name:, **VERIFIED, **attributes).tap { |o| Evidence.create!(subject: o, source: @web, quote: name, found_by: "human") }
  def names = css_select(".nd-live__table tbody td:first-child a").map(&:text)

  test "Live is in the nav with its count; it lists live records by default, newest change first" do
    old = travel_to(2.days.ago) { company("Alpha Live Co") }
    fresh = company("Beta Live Co")
    Organization.create!(name: "Pending Co")

    get admin_live_path(tab: "companies", q: "Live Co")

    assert_select ".nd-shell__nav a[aria-current=page]", /Live\s+\d+/
    assert_equal [ fresh.name, old.name ], names
    assert_select ".nd-fchip[aria-current=true]", /Live\s+2/
  end

  test "chips narrow the list: OR within a group, AND across groups, each with its count" do
    one = company("One Source Co")
    both = company("Both Co")
    Evidence.create!(subject: both, source: Source.create!(url: "https://www.nrc.gov/x", source_kind: "nrc_reactor_list", domain: "nrc.gov"), quote: "x", found_by: "crawler")
    linked = company("Linked Co")
    FacilityRelationship.create!(organization: linked, facility: Facility.create!(name: "Some Plant", **VERIFIED), relationship_type: "owns", **VERIFIED)

    get admin_live_path(tab: "companies", q: " Co", source: "multi-source")
    assert_includes names, both.name
    assert_not_includes names, one.name

    get admin_live_path(tab: "companies", q: " Co", source: "multi-source,hand-research")
    assert_includes names, one.name, "OR within Source"

    get admin_live_path(tab: "companies", q: " Co", source: "hand-research", gaps: "no-links")
    assert_not_includes names, linked.name, "AND across groups"
    assert_includes names, one.name
    no_links = css_select("a.nd-fchip").find { |chip| chip.text.include?("No links") }
    assert_no_match(/gaps=/, no_links["href"], "the chosen chip drops itself")
    assert_select "a", text: "Clear all"
  end

  test "gap and flag counts follow the Status filter: by default, only what visitors see (Data Quality, #283)" do
    company("Seen Co")
    company("Gone Lonely Co").unpublish!(by: "human:tosin", reason: "Test")
    shown = Directory::Checks.find("no-category").ids(Organization) & Organization.published.ids

    get admin_live_path(tab: "companies")
    assert_select "a.nd-fchip", /No category\s+#{shown.size}\b/

    get admin_live_path(tab: "companies", status: "unpublished")
    assert_select "a.nd-fchip", /No category\s+1\b/
    assert_select ".nd-live__foot", /Showing 1 company\b/
  end

  test "No owner counts operating power plants only, not mines or enrichment plants" do
    plant = Facility.create!(name: "Ownerless Power Plant", facility_type: "power_reactor", status: "operating", **VERIFIED)
    mine = Facility.create!(name: "Ownerless Mine", facility_type: "uranium_mine", status: "operating", **VERIFIED)

    ids = Directory::Checks.find("no-owner").ids(Facility)

    assert_includes ids, plant.id
    assert_not_includes ids, mine.id
  end

  test "a status chip replaces the status; Clear all goes back to Live" do
    company("Gone Co").unpublish!(by: "human:tosin", reason: "Test")

    get admin_live_path(tab: "companies", status: "unpublished")

    assert_includes names, "Gone Co"
    assert_select "td", /Company\s+· Removed/
    assert_select "a.nd-fchip[href=?]", admin_live_path(tab: "companies"), /Live/
  end

  test "a row opens a company's or plant's Record, a reactor or link its fact page, each with the way back" do
    c = company("Row Co")
    site = Facility.create!(name: "Row Site", **VERIFIED)
    unit = Facility.create!(name: "Row 1", parent: site, nrc_docket: "05099001", **VERIFIED)

    get admin_live_path(q: "Row")
    assert_select "a[href=?]", admin_record_path(type: "Organization", id: c.id, back: admin_live_path(q: "Row")), "Row Co"
    assert_select "a[href=?]", admin_record_path(type: "Facility", id: site.id, back: admin_live_path(q: "Row")), "Row Site"

    get admin_live_path(tab: "reactors", q: "Row")
    assert_select "a[href=?]", admin_fact_path(type: "Facility", id: unit.id, from: "live", back: admin_live_path(tab: "reactors", q: "Row")), "Row 1"
  end

  test "Record: the public view, status and actions, with Previous and Next through Live" do
    a = travel_to(1.day.ago) { company("Rec A Co", description: "Builds reactors.") }
    b = company("Rec B Co")
    back = admin_live_path(tab: "companies", q: "Rec ")

    get admin_record_path(type: "Organization", id: a.id, back:)

    assert_select ".nd-crumbs li a[href=?]", back, "Live"
    assert_select ".nd-factcard h1", "Rec A Co"
    assert_select ".nd-factcard p", "Builds reactors."
    assert_select ".nd-panel .type-admin-h2", "Live"
    assert_select ".nd-itemnav", /2 of 2/
    assert_select ".nd-itemnav a[rel=prev][href=?]", admin_record_path(type: "Organization", id: b.id, back:)
    assert_select "a", text: "Edit"
    assert_select "a[href=?]", admin_record_merge_path(type: "Organization", id: a.id, back:), "Merge into…"
    assert_select "details summary", /Sources\s+1/
  end

  test "Take off on a Record: Enter in the reason submits it, through the Take off button and its confirm" do
    c = company("Enter Co")

    get admin_record_path(type: "Organization", id: c.id)

    assert_select "form.nd-takeoff__form" do
      assert_select "button[type=submit]", 1, "no hidden button that would swallow Enter"
      assert_select "button[type=submit]:not([disabled])[data-turbo-confirm]", "Take off"
    end
  end

  test "Edit saves changed values as an approval in the history, and Take off comes back to the Record" do
    c = company("Edit Me Co")
    back = admin_live_path

    get admin_record_edit_path(type: "Organization", id: c.id, back:)
    assert_select "input[name=?]", "values[hq_city]"

    patch admin_record_path(type: "Organization", id: c.id, back:), params: { values: { hq_city: "Everett", name: "Edit Me Co" }, note: "From its site" }
    assert_response :see_other
    assert_redirected_to admin_record_path(type: "Organization", id: c.id, back:)
    assert_equal "Everett", c.reload.hq_city
    event = Directory::Lookup.verification_history(type: "Organization", id: c.id).first
    assert_equal [ "From its site", [ nil, "Everett" ] ], [ event.reason, event.changed_values["hq_city"] ]

    post admin_fact_unpublish_path(type: "Organization", id: c.id), params: { reason: "Test", next: admin_record_path(type: "Organization", id: c.id, back:) }
    assert_redirected_to admin_record_path(type: "Organization", id: c.id, back:)
    assert c.reload.unpublished?

    get admin_record_edit_path(type: "Organization", id: c.id)
    assert_match "Put it back first", flash[:alert]
  end

  test "a chip's count includes the group's chips already chosen; Status replaces" do
    a = company("Count A Co")
    b = company("Count B Co")
    Evidence.create!(subject: b, source: Source.create!(url: "https://www.nrc.gov/count", source_kind: "nrc_reactor_list", domain: "nrc.gov"), quote: "x", found_by: "crawler")
    list = Directory::LiveList.new(tab: "companies", query: "Count", chosen: { "source" => [ "nrc" ] })

    assert_equal 1, list.total
    assert_equal 2, list.count("hand-research"), "NRC or research: both companies"
    assert_equal 1, list.count("nrc")
    assert a
  end

  test "Clear all drops the search too, and shows when only a search is active" do
    company("Search Only Co")

    get admin_live_path(q: "Search Only")

    assert_select "a[href=?]", admin_live_path, "Clear all"
    assert_select "form.nd-live__search[data-turbo-action]", 0, "a search is a new entry in the history"
  end

  test "Previous and Next through the Reactors tab open fact pages, as its rows do" do
    a = Facility.create!(name: "Lone Reactor A", nrc_docket: "05099101", **VERIFIED)
    b = Facility.create!(name: "Lone Reactor B", nrc_docket: "05099102", **VERIFIED)
    back = admin_live_path(tab: "reactors", q: "Lone Reactor")

    get admin_fact_path(type: "Facility", id: b.id, from: "live", back:)

    assert_select ".nd-itemnav a[rel=next][href=?]", admin_fact_path(type: "Facility", id: a.id, from: "live", back:)
  end

  test "a pending record is approved by Save and approve with nothing changed; Edit leaves out display-only names" do
    site = Facility.create!(name: "Pending Site", verification_status: "pending")
    Evidence.create!(subject: site, source: @web, quote: "Pending Site", found_by: "human")

    get admin_record_edit_path(type: "Facility", id: site.id)
    assert_select "input[name=?]", "values[parent_name]", 0
    assert_select "input[type=submit][value=?]", "Save and approve"

    patch admin_record_path(type: "Facility", id: site.id), params: { values: { name: "Pending Site" } }

    assert site.reload.verified?
  end

  test "a site with units has no capacity to edit (it's the sum of its units); a standalone reactor keeps its own" do
    site = Facility.create!(name: "Summed Site", capacity_mw: 900, **VERIFIED)
    Facility.create!(name: "Summed 1", parent: site, capacity_mw: 1000, **VERIFIED)
    lone = Facility.create!(name: "Lone Plant", capacity_mw: 500, **VERIFIED)

    get admin_record_edit_path(type: "Facility", id: site.id)
    assert_select "input[name=?]", "values[capacity_mw]", 0
    patch admin_record_path(type: "Facility", id: site.id), params: { values: { capacity_mw: "2000", name: "Summed Site" } }
    assert_equal 900, site.reload.capacity_mw

    get admin_record_edit_path(type: "Facility", id: lone.id)
    assert_select "input[name=?]", "values[capacity_mw]"
  end

  test "changing a website keeps a deliberately blank domain blank" do
    c = company("Shared Site Co", website: "https://group.example/a")
    assert_nil c.domain

    patch admin_record_path(type: "Organization", id: c.id), params: { values: { name: c.name, website: "https://group.example/b", domain: "" } }

    assert_equal "https://group.example/b", c.reload.website
    assert_nil c.domain
  end

  test "an edit that races with a Take off doesn't put the record back" do
    c = company("Race Co")
    stale = DataQuality::Review.fact(type: "Organization", id: c.id) # what the page loaded: live
    c.unpublish!(by: "human:tosin", reason: "Taken off meanwhile")

    real = DataQuality::Review.method(:fact)
    DataQuality::Review.define_singleton_method(:fact) { |**| stale }
    begin
      patch admin_record_path(type: "Organization", id: c.id), params: { values: { hq_city: "Everett" } }
    ensure
      DataQuality::Review.define_singleton_method(:fact, real)
    end

    assert_redirected_to admin_record_path(type: "Organization", id: c.id)
    assert_match "Put it back first", flash[:alert]
    assert c.reload.unpublished?
    assert_nil c.hq_city
  end

  test "the public view shows only what visitors see; a record not public yet shows its own values" do
    bare = Organization.create!(name: "Unsourced Co", description: "Not on the site.", hq_city: "Hidden City", **VERIFIED)
    pending = Organization.create!(name: "Draft Co", description: "Waiting to be checked.")

    get admin_record_path(type: "Organization", id: bare.id)
    assert_select ".nd-factcard", text: /Not on the site|Hidden City/, count: 0

    get admin_record_path(type: "Organization", id: pending.id)
    assert_select ".nd-factcard p", "Waiting to be checked."
  end

  test "a pending site that's public through a verified unit: its own details stay hidden, and Take off is offered" do
    site = Facility.create!(name: "Half Site", city: "Unchecked Town", state: "TX", facility_type: "power_reactor", verification_status: "pending")
    unit = Facility.create!(name: "Half 1", parent: site, **VERIFIED)
    Evidence.create!(subject: unit, source: @web, quote: "Half 1", found_by: "human")
    assert Facility.published.exists?(site.id), "the site is public through its unit"

    get admin_record_path(type: "Facility", id: site.id)

    assert_select ".nd-factcard", text: /Unchecked Town/, count: 0
    assert_select "details.nd-takeoff summary", "Take off"
  end

  test "editing a claim from a fact page opened in Live comes back to it, with Live's way back" do
    reactor = Facility.create!(name: "Claimed Reactor", nrc_docket: "05099201", **VERIFIED)
    claim = Candidate.create!(source: @web, kind: "facility", quote: "q", status: "needs_review", notes: "unsure",
      subject_type: "Facility", subject_id: reactor.id, payload: { "name" => "Claimed Reactor", "nrc_docket" => "05099201", "state" => "TX" })
    Candidate.create!(source: @web, kind: "organization", quote: "q", status: "needs_review", notes: "unsure", payload: { "name" => "Unrelated Co" })
    back = admin_live_path(tab: "reactors")
    fact = admin_fact_path(type: "Facility", id: reactor.id, from: "live", back:)

    get fact
    edit = css_select("a.nd-decide__edit").first["href"]
    assert_equal edit_admin_candidate_path(claim.id, back:, next: fact), edit

    get edit
    assert_select ".nd-itemnav", 0, "no Previous and Next through Checks"
    assert_select ".nd-crumbs a[href=?]", fact

    patch admin_candidate_path(claim.id, back:, next: fact), params: { values: { state: "TX" } }
    assert_redirected_to fact
  end

  test "editing a claim from a Record's waiting link comes back to that fact page too" do
    c = company("Waiting Co")
    claim = Candidate.create!(source: @web, kind: "organization", quote: "q", status: "needs_review", notes: "unsure",
      subject_type: "Organization", subject_id: c.id, payload: { "name" => "Waiting Co", "hq_city" => "Austin" })
    record = admin_record_path(type: "Organization", id: c.id)
    fact = admin_fact_path(type: "Organization", id: c.id, claim: claim.id, back: record)

    get fact
    assert_equal edit_admin_candidate_path(claim.id, back: record, next: fact), css_select("a.nd-decide__edit").first["href"]
  end

  test "a site not public yet shows its own capacity, reactor type and technology" do
    site = Facility.create!(name: "Draft Plant", capacity_mw: 1100, reactor_type: "PWR", verification_status: "pending")

    get admin_record_path(type: "Facility", id: site.id)

    assert_select ".nd-factcard", /1,100 MW/
    assert_select ".nd-factcard", /PWR/
  end

  test "Take off and Put back on a pending site public through its unit leaves it pending, its units public again" do
    site = Facility.create!(name: "Round Trip Site", verification_status: "pending")
    unit = Facility.create!(name: "Round Trip 1", parent: site, **VERIFIED)
    Evidence.create!(subject: unit, source: @web, quote: "Round Trip 1", found_by: "human")

    post admin_fact_unpublish_path(type: "Facility", id: site.id), params: { reason: "Test" }
    assert_not Facility.published.exists?(unit.id)

    post admin_fact_republish_path(type: "Facility", id: site.id)

    assert_equal "pending", site.reload.verification_status, "its own fields stay unapproved"
    assert Facility.published.exists?(unit.id)

    site.verify!(by: "human:tosin")
    post admin_fact_republish_path(type: "Facility", id: site.id)
    assert_equal "verified", site.reload.verification_status, "an old Put back form doesn't undo a newer approval"
  end

  test "a unit has no Record page; its fact page opened from Live says Live" do
    site = Facility.create!(name: "Unit Site", **VERIFIED)
    unit = Facility.create!(name: "Unit 1", parent: site, **VERIFIED)

    get admin_record_path(type: "Facility", id: unit.id)
    assert_response :not_found

    get admin_fact_path(type: "Facility", id: unit.id, from: "live", back: admin_live_path(tab: "reactors"))
    assert_select ".nd-crumbs li a[href=?]", admin_live_path(tab: "reactors"), "Live"
  end

  test "tag ids and tab counts are cached until the directory or a claim changes (Infra: 10 s, 800+ queries)" do
    store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    load_page = lambda do
      queries = reads = 0
      sql = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, p| queries += 1 unless p[:name] == "SCHEMA" }
      cache = ActiveSupport::Notifications.subscribe("cache_read.active_support") { reads += 1 }
      get admin_live_path
      ActiveSupport::Notifications.unsubscribe(sql)
      ActiveSupport::Notifications.unsubscribe(cache)
      [ queries, reads ]
    end
    first, = load_page.call
    tabs = -> { response.body[/<nav class="nd-fchips[\s\S]*?<\/nav>/] }
    body = tabs.call
    second, reads = load_page.call
    assert_operator second, :<, first * 0.7, "#{first} then #{second}"
    assert_operator second, :<=, 90, "an absolute ceiling for a warm load"
    assert_operator reads, :<=, 3, "the tag map and the tab counts: one cache read each (Solid Cache reads are queries)"
    assert_equal body, tabs.call, "same tab counts"

    Organization.create!(name: "New Live Co", verification_status: "verified", verified_by: "human:tosin")
    DataVersion.expire!
    get admin_live_path
    assert_not_equal body, tabs.call, "a change shows at once"
  ensure
    Rails.cache = store
  end

  test "the stamp changes with any claim change, even one committed with an older timestamp, and with a decision" do
    page = Source.create!(url: "https://example.com/stamp", source_kind: "dummy", crawl_status: "ok")
    claim = Candidate.create!(source: page, kind: "organization", payload: { "name" => "X" }, quote: "q", status: "new")
    stamp = -> { Current.reset; Directory::LiveList.stamp }
    before = stamp.call
    claim.update_columns(status: "rejected", updated_at: 1.year.ago)
    refute_equal before, (after = stamp.call), "an out-of-order write"
    VerificationEvent.create!(subject: Organization.create!(name: "Y"), to_status: "unpublished", by: "human:tosin")
    refute_equal after, stamp.call, "another process's decision, without waiting for DataVersion's memo"
  end
end
