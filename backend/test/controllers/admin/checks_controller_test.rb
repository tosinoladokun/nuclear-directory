require "test_helper"

# Checks (#201): each waiting claim in exactly one group, pending facts
# under Facts, a filter by source, and paging from claims into pending
# facts. Overview's tiles and source table, and the phone menu.
class Admin::ChecksControllerTest < ActionDispatch::IntegrationTest
  setup do
    @nrc = Source.create!(url: "https://www.nrc.gov/test/checks.html", source_kind: "nrc_reactor_list", crawl_status: "ok")
    @web = Source.create!(url: "https://www.sec.gov/filing.htm", source_kind: "web_page", crawl_status: "ok")
    sign_in_as users(:admin)
  end

  def waiting(kind, payload, notes:, source: @nrc)
    Candidate.create!(source:, kind:, payload:, quote: "q", status: "needs_review", notes:)
  end

  def claims_shown = css_select(".nd-waits > li[id^=claim-]").map { |li| li["id"].delete_prefix("claim-").to_i }

  test "each waiting claim is in one group: changed, duplicate, link, else fact" do
    changed = waiting("facility", { "name" => "Hope Creek 1" }, notes: "human-verified state is NJ; this source says DE")
    duplicate = waiting("organization", { "name" => "GENERAL ATOMICS" }, notes: 'no exact match for "GENERAL ATOMICS", but similar: General Matter. Same record, or a new one?')
    brand = waiting("relationship", { "from_organization" => { "name" => "DOE" }, "to_organization" => { "name" => "Urenco USA" }, "relationship_type" => "funds" },
      notes: 'to_organization: "Urenco USA" could be the same brand as Urenco. Which one?')
    link = waiting("relationship", { "from_organization" => { "name" => "Amazon" }, "to_organization" => { "name" => "Talen Energy" },
      "relationship_type" => "offtakes_from" }, notes: "unsure", source: @web)
    fact = waiting("organization_role", { "organization" => { "name" => "Kairos Power" }, "role" => "reactor_vendor" }, notes: nil)
    pending = DataQuality::Review.pending_count

    assert_equal({ "all" => 5, "changed" => 1, "links" => 1, "facts" => 1, "duplicates" => 2 }, DataQuality::Review.check_counts)

    get admin_checks_path
    assert_select ".nd-fchip", /Facts\s+#{1 + pending}/
    assert_select ".nd-fchip", /All\s+#{5 + pending}/

    { "changed" => [ changed ], "duplicates" => [ duplicate, brand ], "links" => [ link ], "facts" => [ fact ] }.each do |category, expected|
      get admin_checks_path(category:)
      assert_equal expected.map(&:id), claims_shown, category
    end

    get admin_checks_path(category: "duplicates")
    assert_select "#claim-#{duplicate.id} .type-kicker", "Duplicate · NRC"
    assert_select "#claim-#{duplicate.id} .type-change", "→ General Matter"
    assert_select "#claim-#{brand.id} .type-change", "→ Urenco"
    get admin_checks_path(category: "links")
    assert_select "#claim-#{link.id} .type-kicker", "New link · Research"
    assert_select "#claim-#{link.id} .type-subject", "Amazon offtakes from Talen Energy"
  end

  test "an EIA claim for a unit already in the directory reads as an update: the unit and its capacity" do
    eia = Source.create!(url: "https://www.eia.gov/generators.xlsx", source_kind: "eia_generators", crawl_status: "ok")
    unit = Facility.create!(name: "Catawba 2", nrc_docket: "05000414", verification_status: "verified", verified_by: "human:tosin")
    attached = Candidate.create!(source: eia, kind: "facility", quote: "q", status: "needs_review", notes: "unsure", subject_type: "Facility",
      subject_id: unit.id, payload: { "identify" => { "name" => "Catawba", "unit" => "2", "eia_plant_id" => "6036" }, "capacity_mw" => "1160.0" })
    waiting = Candidate.create!(source: eia, kind: "facility", quote: "q", status: "needs_review", notes: "unsure",
      payload: { "identify" => { "name" => "Crane Clean Energy Center", "unit" => "1" }, "capacity_mw" => "802.8" })

    get admin_checks_path(category: "facts")

    assert_select "#claim-#{attached.id}" do
      assert_select ".type-kicker", "Update · EIA"
      assert_select ".type-subject", "Catawba 2"
      assert_select ".type-change", "1,160 MW"
    end
    assert_select "#claim-#{waiting.id} .type-subject", "Crane Clean Energy Center unit 1"
    assert_select "#claim-#{waiting.id} .type-change", "802.8 MW"
  end

  test "a source filter narrows the claims and leaves pending facts out" do
    from_nrc = waiting("organization", { "name" => "Alpha Co" }, notes: "unsure")
    waiting("organization", { "name" => "Beta Co" }, notes: "unsure", source: @web)

    get admin_checks_path(source: "nrc_reactor_list")

    assert_equal [ from_nrc.id ], claims_shown
    assert_select ".nd-waits > li[id^=fact-]", 0
    assert_select ".nd-fchip", /All\s+1/
    assert_select ".nd-fchip[aria-current=page][href=?]", admin_checks_path, /NRC/
  end

  test "pages through claims, then pending facts kind by kind, each once" do
    stub_const(Admin::ChecksController, :PAGE, 2) do
      claims = 3.times.map { |n| waiting("organization", { "name" => "Co #{n}" }, notes: "unsure") }
      pending = DataQuality::Review.fact_kinds.flat_map { |kind| DataQuality::Review.pending_facts(kind:, limit: 100) }
      assert_operator pending.size, :>=, 2, "the fixtures have pending facts"

      seen_claims = []
      seen_facts = []
      get admin_checks_path
      loop do
        seen_claims.concat(claims_shown)
        seen_facts.concat(css_select(".nd-waits > li[id^=fact-]").map { |li| li["id"] })
        assert_operator css_select(".nd-waits > li").size, :<=, 2
        next_link = css_select("a").find { |a| a.text == "Next 2" } or break
        get next_link["href"]
      end

      assert_equal claims.map(&:id), seen_claims
      assert_equal pending.map { |fact| "fact-#{fact.type}-#{fact.id}" }, seen_facts
    end
  end

  test "Overview: today's date, a tile per stage with its count, and each source's read, same and changed" do
    waiting("organization", { "name" => "Alpha Co" }, notes: "unsure")
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago, finished_at: 1.hour.ago,
      stats: { "candidates" => 219, "confirmed" => 219 })
    CorrectionReport.create!(subject: "TerraPower", page_path: "/", message: "Typo.")

    get admin_root_path

    assert_response :success
    assert_select "h1", "Today"
    assert_select ".nd-shell__nav a[aria-current=page]", "Overview"
    assert_select "a.nd-tile[href=?]", admin_checks_path, /Checks · waiting\s+#{1 + DataQuality::Review.pending_count}/
    assert_select "a.nd-tile.nd-tile--ink", 1
    assert_select "a.nd-tile[href=?]", admin_corrections_path, /Correction requests\s+1/
    row = css_select(".nd-numtable tbody tr").find { |tr| tr.text.include?("NRC") }
    assert_equal [ "NRC", "219", "219", "1" ], row.css("td").map { |td| td.text.squish }
  end

  test "the nav folds behind Menu on phones; without JavaScript it stays open" do
    get admin_root_path

    assert_select "header.nd-shell__side[data-controller=admin-menu]" do
      assert_select "button.nd-shell__menu[hidden][aria-controls=admin-nav]", "Menu"
      assert_select "nav#admin-nav a", 5
    end
    assert_select ".nd-shell__nav a", /Today/
    assert_select ".nd-shell__nav a", text: /Queue|Pending facts/, count: 0
  end
end
