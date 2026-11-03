require "test_helper"

# #696: instant search's index, published companies and plant sites only.
class SearchIndexTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze

  setup do
    @company = Organization.create!(name: "Index Reactors", slug: "index-reactors", short_name: "IR", short_description: "Small reactors",
      hq_city: "Austin", hq_state: "TX", verification_status: "verified", verified_by: BY)
    @company.aliases.create!(alias: "Index Reactors")
    @company.aliases.create!(alias: "IR Nuclear")
    Organization.create!(name: "Hidden Index Co", slug: "hidden-index", verification_status: "pending")
    @site = Facility.create!(name: "Index Station", slug: "index-station", facility_type: "power_reactor", city: "Glen Rose", state: "TX",
      verification_status: "verified", verified_by: BY)
    @site.aliases.create!(alias: "Index Nuclear Station")
    @site.update!(eia_plant_id: "6145")
    Facility.create!(name: "Hidden Unit", slug: "hidden-unit", parent: @site, verification_status: "pending")
    Facility.create!(name: "Index Station 1", slug: "index-station-1", parent: @site, nrc_docket: "05000445", verification_status: "verified", verified_by: BY)
    @company.update!(exchange: "NYSE", ticker: "IDXR")
    page = Source.create!(url: "https://example.com/index-reactors", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t")
    Evidence.create!(subject: @company, source: page, quote: "t", found_by: "human")
  end

  def index_json = (get search_index_path; JSON.parse(response.body))

  test "published companies and plant sites, compact, with other names, the results line and each icon once" do
    json = index_json
    company = json["items"].find { |c| c["s"] == "index-reactors" }
    assert_equal({ "k" => "c", "s" => "index-reactors", "n" => "Index Reactors", "sn" => "IR", "a" => [ "IR Nuclear" ], "d" => "Small reactors",
      "m" => "Austin, TX", "i" => "buildings-16", "c" => 0, "x" => [ "IDXR" ] }, company)
    assert_nil json["items"].find { |c| c["s"] == "hidden-index" }, "unpublished stays out"
    plant = json["items"].find { |p| p["s"] == "index-station" }
    assert_equal [ "p", [ "Index Nuclear Station", "Index Station 1" ], "Power plant · Glen Rose, TX" ], plant.values_at("k", "a", "m")
    assert_match "<svg", json["icons"].fetch(plant["i"])
    assert_equal [ "6145", "05000445" ], plant["x"], "the site's EIA ID and its unit's docket"
    assert_equal PublicPages.new.tags.map(&:key), json["tags"].map { |tag| tag["s"] }
    assert_equal (json["items"] + json["tags"]).filter_map { |item| item["i"] }.uniq.sort, json["icons"].keys.sort
    assert_equal SearchIndex.version, json["v"]
  end

  test "an ETag of its version: 304 while nothing changed, new once a record does; no session cookie" do
    get search_index_path
    etag = response.headers["ETag"]
    assert_nil response.headers["Set-Cookie"]
    assert_match "public", response.headers["Cache-Control"]
    get search_index_path, headers: { "If-None-Match" => etag }
    assert_response :not_modified
    @company.update!(short_description: "Microreactors")
    get search_index_path, headers: { "If-None-Match" => etag }
    assert_response :success
    assert_equal "Microreactors", JSON.parse(response.body)["items"].find { |c| c["s"] == "index-reactors" }["d"]
  end

  test "topics: a tag that lists someone, with its words, count and icon" do
    role = Role.find_or_create_by!(key: "enrichment") { |r| r.name = "Enrichment" }
    link = OrganizationRole.create!(organization: @company, role:, verification_status: "verified", verified_by: BY)
    page = Source.create!(url: "https://example.com/enrich", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t")
    Evidence.create!(subject: link, source: page, quote: "t", found_by: "human")
    hidden = Organization.create!(name: "Hidden Enricher", slug: "hidden-enricher", verification_status: "pending")
    hidden_link = OrganizationRole.create!(organization: hidden, role:, verification_status: "verified", verified_by: BY)
    Evidence.create!(subject: hidden_link, source: page, quote: "t", found_by: "human")
    tag = index_json["tags"].find { |t| t["s"] == "enrichment" }
    assert_equal [ "Enrichment", 1 ], tag.values_at("n", "c")
    assert_includes tag["a"], "haleu"
  end

  test "an unsourced short description stays out; the version moves with evidence, roles, deals and the date" do
    other = Organization.create!(name: "Unsourced Co", slug: "unsourced-co", short_description: "Says so itself", verification_status: "verified", verified_by: BY)
    assert_nil index_json["items"].find { |c| c["s"] == "unsourced-co" }["d"]

    before = SearchIndex.version
    Evidence.create!(subject: other, source: Source.first, quote: "t", found_by: "human")
    assert_not_equal before, (after_evidence = SearchIndex.version)
    Role.find_or_create_by!(key: "isotopes") { |r| r.name = "Isotopes" }.touch
    assert_not_equal after_evidence, (after_role = SearchIndex.version)
    travel 1.day do
      assert_not_equal after_role, SearchIndex.version
    end
  end
end
