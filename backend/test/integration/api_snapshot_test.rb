require "test_helper"
require_relative "../support/directory_builders"

# GET /api/snapshot.json (#193): the public summary other sites read.
class ApiSnapshotTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    DirectorySnapshot.expire!
    Api::SnapshotsController::RATE_LIMIT_STORE.clear

    vendor = role("reactor_vendor")
    utility = role("utility")
    @kairos = company("Kairos Power", roles: [ vendor ], verified_at: 3.days.ago)
    @nuscale = company("NuScale Power", roles: [ vendor ], verified_at: 2.days.ago)
    # In two categories: utilities, and investors through its deal.
    @duke = company("Duke Energy", roles: [ utility ], verified_at: 1.day.ago)
    cite!(link(@duke, "invests_in", @kairos))
    @vogtle = plant("Vogtle", verified_at: 4.days.ago)
    @hidden = company("Pending Co", verified: false)
    @gone = company("Gone Co").tap { |gone| gone.unpublish!(by: "human:test", reason: "test") }
    cite!(@kairos, @nuscale, @duke)
  end

  # Every fact table reports no rows, as on an empty database.
  def with_no_facts
    DirectorySnapshot::FACT_MODELS.each { |model| model.define_singleton_method(:maximum) { |*| nil } }
    yield
  ensure
    DirectorySnapshot::FACT_MODELS.each { |model| model.singleton_class.send(:remove_method, :maximum) }
  end

  def snapshot
    get "/api/snapshot.json"
    response.parsed_body
  end

  test "the shape other sites rely on: names and types of every field" do
    body = snapshot

    assert_response :success
    assert_equal %w[categories recentlyAdded totalEntries updatedAt], body.keys.sort
    assert_kind_of Integer, body["totalEntries"]
    assert_nothing_raised { Time.iso8601(body["updatedAt"]) }

    assert_equal %w[reactor-developers utilities plants investors],
      body["categories"].map { |c| c["slug"] }, "the buckets with companies, and Plants and sites, in the site's order (#281)"
    body["categories"].each do |category|
      assert_equal %w[count examples name slug url], category.keys.sort
      assert_kind_of Integer, category["count"]
      %w[slug name url].each { |field| assert_kind_of String, category[field], "#{category['slug']}.#{field}" }
      assert_kind_of Array, category["examples"]
      assert category["examples"].all?(String) && category["examples"].size <= 2, category["slug"]
    end

    body["recentlyAdded"].each do |entry|
      assert_equal %w[addedAt category location name url], entry.keys.sort
      %w[name category url].each { |field| assert_kind_of String, entry[field], field }
      assert entry["location"].nil? || entry["location"].is_a?(String), "location is a string or null"
      assert_match(/\A\d{4}-\d{2}-\d{2}\z/, entry["addedAt"])
    end
  end

  test "each recent addition gives its place as its page shows it: City, ST, the state alone, or null (#225)" do
    @kairos.update!(hq_city: "Alameda", hq_state: "CA")
    @nuscale.update!(hq_city: nil, hq_state: "OR")
    @vogtle.update!(city: "Waynesboro", state: "GA")
    cite!(@vogtle)
    pending = plant("Pending Site", verified: false, city: "Nowhere", state: "TX")
    cite!(plant("Pending Site 1", parent: pending, verified_at: 1.hour.ago))

    places = snapshot["recentlyAdded"].to_h { |entry| [ entry["name"], entry["location"] ] }

    assert_equal "Alameda, CA", places["Kairos Power"]
    assert_equal "OR", places["NuScale Power"]
    assert_nil places["Duke Energy"], "no HQ stored"
    assert_equal "Waynesboro, GA", places["Vogtle"]
    assert places.key?("Pending Site"), "public for its published unit"
    assert_nil places["Pending Site"], "a pending site's own place isn't shown, as on its page"
  end

  test "at most five recent additions, however many there are" do
    6.times { |i| company("Recent #{i}", verified_at: i.minutes.ago) }
    DirectorySnapshot.expire!

    recent = snapshot["recentlyAdded"]

    assert_equal 5, recent.size
    assert_equal (0..4).map { |i| "Recent #{i}" }, recent.map { |e| e["name"] }
  end

  test "in production, links use the live site's address, never the request's Host" do
    env = Rails.env
    env.define_singleton_method(:production?) { true }

    assert_equal "https://nuclear-directory.org", Api::SnapshotsController.new.send(:origin), "no request needed, so no Host to trust"
  ensure
    env.singleton_class.send(:remove_method, :production?)
  end

  test "counts follow the documented rule: entries once in the total, categories may overlap" do
    body = snapshot
    counts = body["categories"].to_h { |c| [ c["slug"], c["count"] ] }

    assert_equal 4, body["totalEntries"], "3 published companies and 1 site; pending and unpublished left out"
    assert_equal({ "reactor-developers" => 2, "utilities" => 1, "investors" => 1, "plants" => 1 }, counts.select { |_, n| n.positive? })
    assert counts.values.all? { |n| n <= body["totalEntries"] }
    assert_equal 1, counts["plants"], "Plants and sites counts every published site"
    assert_operator counts.values.sum, :>, body["totalEntries"] - counts["plants"], "Duke is counted in two categories"
  end

  test "examples and recent additions name only published entries, newest first" do
    body = snapshot
    names = body["categories"].flat_map { |c| c["examples"] } + body["recentlyAdded"].map { |e| e["name"] }

    assert_not_includes names, "Pending Co"
    assert_not_includes names, "Gone Co"
    assert_equal [ "Duke Energy", "NuScale Power", "Kairos Power", "Vogtle" ], body["recentlyAdded"].map { |e| e["name"] }
    assert_equal [ "Utilities and operators", "Developers", "Developers", "Plants and sites" ],
      body["recentlyAdded"].map { |e| e["category"] }
    assert_equal 1.day.ago.to_date.iso8601, body["recentlyAdded"].first["addedAt"]
    assert_equal [ "Duke Energy" ], body["categories"].find { |c| c["slug"] == "investors" }["examples"]
  end

  test "every url opens a real page on the site" do
    body = snapshot
    urls = body["categories"].map { |c| c["url"] } + body["recentlyAdded"].map { |e| e["url"] }

    urls.each do |url|
      assert url.start_with?("http://www.example.com/"), url
      get URI(url).request_uri
      assert_response :success, url
    end
  end

  test "public, cacheable JSON for any origin; read from memory after the first request" do
    snapshot

    assert_equal "application/json", response.media_type
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
    assert_equal %w[max-age=300 public s-maxage=3600 stale-while-revalidate=86400],
      response.headers["Cache-Control"].split(", ").sort
    assert_no_queries { get "/api/snapshot.json" }
    assert_response :success
  end

  test "a snapshot built while a fact changed is never served after the change" do
    built = 0
    original = DirectorySnapshot.method(:new)
    DirectorySnapshot.define_singleton_method(:new) do |**args|
      built += 1
      snapshot = original.call(**args)
      # The first build sees a fact commit halfway through.
      snapshot.define_singleton_method(:as_json) { |*| DirectorySnapshot.expire!; { "stale" => true } } if built == 1
      snapshot
    end

    assert_equal({ "stale" => true }, DirectorySnapshot.current(base_url: "https://example.com"))
    assert_equal 4, DirectorySnapshot.current(base_url: "https://example.com")[:totalEntries], "rebuilt, not the stale copy"
  ensure
    DirectorySnapshot.singleton_class.remove_method(:new)
  end

  test "a site dates from its first published unit, even if the site itself was verified later" do
    site = plant("Palisades", verified: false)
    plant("Palisades 1", parent: site, verified_at: 10.days.ago, facility_type: "power_reactor")
    site.verify!(by: "human:test") # today, after its unit
    DirectorySnapshot.expire!

    palisades = DirectorySnapshot.new(base_url: "https://example.com").send(:recently_added).find { |e| e[:name] == "Palisades" }
    assert_equal 10.days.ago.to_date.iso8601, palisades[:addedAt]
  end

  test "updatedAt moves forward with any change that feeds the snapshot, removals included" do
    before = Time.iso8601(snapshot["updatedAt"])

    travel 1.minute do
      OrganizationRole.create!(organization: @duke, role: role("data_center_offtaker"), **verification(true))
      after_publish = Time.iso8601(snapshot["updatedAt"])
      assert_operator after_publish, :>, before
    end

    travel 2.minutes do
      @kairos.unpublish!(by: "human:tosin", reason: "test")
      assert_operator Time.iso8601(snapshot["updatedAt"]), :>, before + 1.minute
    end
  end

  test "updatedAt is always a time, and a deleted fact's last change still counts" do
    newest = company("Newest Co")
    travel 5.minutes do
      newest.destroy!
      # Nothing left in the tables is this new: the recorded change time is.
      assert_operator Time.iso8601(snapshot["updatedAt"]), :>=, Time.current.change(usec: 0) - 1.second
    end

    # An empty directory with nothing recorded still gives a time.
    DirectorySnapshot::CHANGES.clear
    with_no_facts do
      assert_kind_of Time, DirectorySnapshot.new(base_url: "https://example.com").send(:updated_at)
    end
  end

  test "publishing or unpublishing a fact shows in the next snapshot" do
    assert_equal 4, snapshot["totalEntries"]

    company("Oklo", verified_at: Time.current)
    assert_equal 5, snapshot["totalEntries"]
    assert_equal "Oklo", snapshot["recentlyAdded"].first["name"]

    @nuscale.unpublish!(by: "human:tosin", reason: "test")
    assert_equal 4, snapshot["totalEntries"]
  end

  test "read-only, and rate limited per visitor" do
    post "/api/snapshot.json"
    assert_response :not_found

    Api::SnapshotsController::RATE_LIMIT.times { get "/api/snapshot.json" }
    assert_response :success
    get "/api/snapshot.json"
    assert_response :too_many_requests
    assert_equal "*", response.headers["Access-Control-Allow-Origin"]
  end
end
