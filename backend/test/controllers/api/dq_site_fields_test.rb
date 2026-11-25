require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #916: Data Quality proposes a published site's sourced coordinates and EIA
# plant ID, for the homepage map (#909). One plant claim on that site, shown
# to Tosin as old → new; a blank fill may join Yes to all, a change to his
# value stays his own.
class Api::DqSiteFieldsTest < ActionDispatch::IntegrationTest
  TOKEN = "dq-test-token".freeze
  QUOTE = "Site centre: latitude 41.705993, longitude -110.5603. EIA plant ID 68635.".freeze

  setup do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    @site = Facility.create!(name: "Kemmerer Power Station", facility_type: "power_reactor", status: "under_construction", state: "WY",
      verification_status: "verified", verified_by: "human:tosin")
    @page = Source.create!(url: "https://example.com/kemmerer", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: QUOTE)
  end

  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  def act(*rows) = post(api_dq_matching_path, params: { actions: rows }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" })
  def results = response.parsed_body["results"]
  def propose(fields, target: @site.id, quote: QUOTE, **rest) =
    { action: "propose_site_fields", target:, fields:, quote:, source_url: @page.url, reason: "Their own page", **rest }
  def coordinates = { latitude: "41.705993", longitude: "-110.5603" }
  def match! = DataQuality::Stages::Match.call(plugin: DummyPlugin.new)

  test "coordinates and an EIA plant ID become one plant claim on the site, a Change for Tosin; nothing written until his Yes; undo closes it" do
    act(propose(coordinates.merge(eia_plant_id: "68635")))
    assert results.sole["ok"], results.inspect
    claim = Candidate.find(results.sole["id"])
    assert_equal "facility", claim.kind
    assert_equal({ "name" => "Kemmerer Power Station", "latitude" => "41.705993", "longitude" => "-110.5603", "eia_plant_id" => "68635" }, claim.payload)
    assert_equal [ "Facility", @site.id ], DqAction.sole.values_at(:target_type, :target_id)

    match!
    assert_equal [ "Facility", @site.id ], claim.reload.values_at(:subject_type, :subject_id), claim.notes
    assert_equal "change", DataQuality::Review.inbox_kind(claim)
    changes = DataQuality::Differences.changes(claim, DataQuality::DirectoryClient.new.fact(type: "Facility", id: @site.id), directory: DataQuality::DirectoryClient.new)
    assert_equal({ "latitude" => [ nil, "41.705993" ], "longitude" => [ nil, "-110.5603" ], "eia_plant_id" => [ nil, "68635" ] }, changes, "shown old → new")
    assert_nil @site.reload.latitude, "nothing written before Tosin decides"

    assert DataQuality::Review.approve([ claim.id ], by: "human:tosin").sole.ok?
    assert_equal [ BigDecimal("41.705993"), BigDecimal("-110.5603"), "68635" ], @site.reload.values_at(:latitude, :longitude, :eia_plant_id)

    act(propose(coordinates))
    assert_nil DataQuality::Matching.undo(DqAction.last.id)
    assert_equal "rejected", Candidate.find(results.sole["id"]).status
  end

  test "only a published top-level site: never a unit, a pending site or a company" do
    unit = Facility.create!(name: "Kemmerer Unit 1", facility_type: "power_reactor", parent: @site, nrc_docket: "05000613",
      verification_status: "verified", verified_by: "human:tosin")
    pending = Facility.create!(name: "Pending Site", facility_type: "power_reactor", verification_status: "pending")
    act(propose(coordinates, target: unit.id), propose(coordinates, target: pending.id), propose(coordinates, target: "no-such-site"),
      propose(coordinates, target: "https://nuclear-directory.org/plants/#{@site.slug}"), propose(coordinates, target: @site.slug))
    assert_match "is a unit", results.first["error"]
    assert_match "isn't published", results.second["error"]
    assert_match "no open plant", results.third["error"]
    assert results.fourth["ok"], "its page's address works"
    assert results.fifth["ok"], "its slug works"
  end

  test "coordinates come as a pair, in range, with 3 to 6 decimals; only these fields" do
    act(propose({ latitude: "41.705993" }),
      propose({ latitude: "91.000", longitude: "-110.560" }, quote: "91.000, -110.560"),
      propose({ latitude: "41.705993", longitude: "-181.000" }, quote: "41.705993 -181.000"),
      propose({ latitude: "41.71", longitude: "-110.5603" }, quote: "41.71 -110.5603"),
      propose({ latitude: "41.7059931", longitude: "-110.5603" }, quote: "41.7059931 -110.5603"),
      propose({ latitude: "41 N", longitude: "-110.5603" }),
      propose({ state: "WY" }),
      propose({ latitude: "", longitude: "-110.5603" }),
      propose([ "latitude" ]))
    assert_match "go together", results[0]["error"]
    assert_match "latitude must be between -90 and 90", results[1]["error"]
    assert_match "longitude must be between -180 and 180", results[2]["error"]
    assert_match "3 to 6 decimal places", results[3]["error"]
    assert_match "3 to 6 decimal places", results[4]["error"], "the directory keeps 6"
    assert_match "3 to 6 decimal places", results[5]["error"]
    assert_match "only latitude, longitude, eia_plant_id", results[6]["error"]
    assert_match "a value for every field", results[7]["error"]
    assert_match "give fields", results[8]["error"]
  end

  test "the quote must state both numbers, decimal as written or in degrees, minutes and seconds" do
    act(propose(coordinates, quote: "Kemmerer is near Kemmerer, Wyoming."),
      propose(coordinates, quote: "latitude 41.705993, longitude 110.5603"),
      propose(coordinates, quote: "41.705993 N, 110.5603 W"),
      propose(coordinates, quote: "41°42'21.57\" N 110°33'37.08\" W"),
      propose(coordinates, quote: "41°42'22.6\" N 110°33'37.08\" W"))
    assert_match "must state the latitude", results[0]["error"]
    assert_match "must state the longitude -110.5603", results[1]["error"], "a positive 110.5603 isn't -110.5603"
    assert results[2]["ok"], "W gives the sign: #{results[2].inspect}"
    assert results[3]["ok"], "DMS within the source's precision: #{results[3].inspect}"
    assert_match "must state the latitude", results[4]["error"], "a second off is outside a 0.1-second source"
  end

  test "an EIA plant ID is digits, in the quote, and no other site's" do
    Facility.create!(name: "Naughton", facility_type: "other", eia_plant_id: "4162", verification_status: "verified", verified_by: "human:tosin")
    act(propose({ eia_plant_id: "68A35" }), propose({ eia_plant_id: "68636" }),
      propose({ eia_plant_id: "4162" }, quote: "EIA plant ID 4162"), propose({ eia_plant_id: "68635" }))
    assert_match "is digits", results[0]["error"]
    assert_match "must contain the EIA plant ID 68636", results[1]["error"]
    assert_match "already Naughton's", results[2]["error"]
    assert results[3]["ok"], results.inspect
  end

  test "a different match goes to review, never to that site" do
    act(propose(coordinates))
    claim = Candidate.find(results.sole["id"])
    # Renamed before matching, and another plant now has the old name: not that one.
    @site.update!(name: "Natrium Kemmerer")
    other = Facility.create!(name: "Kemmerer Power Station", facility_type: "other", verification_status: "verified", verified_by: "human:tosin")
    match!
    assert_nil claim.reload.subject_id
    assert_match "proposed for site ##{@site.id}, but it matches Kemmerer Power Station (by name)", claim.notes
    assert_nil other.reload.latitude

    # Matching nothing goes to review too, never proposing a new plant.
    act(propose(coordinates))
    lost = Candidate.find(results.sole["id"])
    lost.update!(payload: lost.payload.merge("name" => "Nowhere"))
    assert_no_difference -> { Facility.count } do
      match!
    end
    assert_match "proposed for site ##{@site.id}, but it doesn't match that site", lost.reload.notes
  end

  test "a blank fill with Data Quality's approve joins Yes to all; a change to Tosin's coordinates stays his own" do
    Evidence.create!(subject: @site, source: @page, quote: QUOTE, found_by: "human")
    other = Facility.create!(name: "Shirley Basin", facility_type: "uranium_mine", latitude: 42.1, longitude: -106.2,
      verification_status: "verified", verified_by: "human:tosin")
    act(propose(coordinates), propose({ latitude: "42.123", longitude: "-106.456" }, target: other.id, quote: "42.123, -106.456"))
    @page.update!(content_text: "#{QUOTE} 42.123, -106.456")
    fill, change = results.map { |r| Candidate.find(r["id"]) }
    match!
    [ fill, change ].each { |c| act({ id: c.id, action: "recommend", verdict: "approve", reason: "On their page" }) }

    inbox = OwnerInbox.new
    assert_equal [ fill.id ], inbox.checked.map { |entry| entry.item.candidate_id }, "only the blank fill joins the one button"
    assert DataQuality::Recommendations.accept(inbox.checked_items, by: "human:tosin", first_hand: true).sole.ok?
    assert_equal BigDecimal("41.705993"), @site.reload.latitude
    assert_equal BigDecimal("42.1"), other.reload.latitude, "never overwritten in bulk"
    assert_equal "change", DataQuality::Review.inbox_kind(change.reload)
  end

  test "the same daily limit as the other proposals, and a retry with its request_key is answered first" do
    act(propose(coordinates, request_key: "k1"))
    first = results.sole["id"]
    act(propose(coordinates, request_key: "k1"))
    assert_equal first, results.sole["id"]
    stub_const(DataQuality::Matching, :DAILY_ROLES, 1) do
      act(propose(coordinates))
      assert_match "today's limit of 1 is reached for propose_site_fields", results.sole["error"]
    end
  end

  def stub_const(mod, name, value)
    old = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, old)
  end
end
