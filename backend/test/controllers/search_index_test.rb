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
  end

  def index_json = (get search_index_path; JSON.parse(response.body))

  test "published companies and plant sites, compact, with other names, the results line and each icon once" do
    json = index_json
    company = json["items"].find { |c| c["s"] == "index-reactors" }
    assert_equal({ "k" => "c", "s" => "index-reactors", "n" => "Index Reactors", "sn" => "IR", "a" => [ "IR Nuclear" ], "d" => "Small reactors",
      "m" => "Austin, TX", "i" => "buildings-16", "c" => 0 }, company)
    assert_nil json["items"].find { |c| c["s"] == "hidden-index" }, "unpublished stays out"
    plant = json["items"].find { |p| p["s"] == "index-station" }
    assert_equal [ "p", [ "Index Nuclear Station" ], "Power plant · Glen Rose, TX" ], plant.values_at("k", "a", "m")
    assert_match "<svg", json["icons"].fetch(plant["i"])
    assert_equal json["items"].map { |item| item["i"] }.uniq.sort, json["icons"].keys.sort
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
end
