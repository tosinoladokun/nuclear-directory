require "test_helper"
require_relative "../support/directory_builders"
require_relative "../support/fake_posthog"
require_relative "../support/fake_geo_reader"

# The server-side events the real pages send (#68): a company or plant page
# viewed, and a correction sent. They were defined but never called.
class AnalyticsEventsTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders
  include AnalyticsTestHelper

  BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

  # The corrections form's rate limit is process-wide; another test may have used it up.
  setup { CorrectionsController::RATE_LIMIT_STORE.clear }

  def visit(path) = get(path, headers: { "User-Agent" => BROWSER })

  test "a company page sends company_viewed with its slug" do
    kairos = cite!(company("Kairos Power"))

    visit company_path(slug: kairos.slug)

    assert_response :success
    assert_equal [ [ "company_viewed", kairos.slug ] ], posthog.events.map { |e| [ e[:event], e[:properties]["slug"] ] }
  end

  test "a page fetched ahead of a click (hover prefetch) isn't a view" do
    kairos = cite!(company("Kairos Power"))

    [ { "X-Sec-Purpose" => "prefetch" }, { "Sec-Purpose" => "prefetch;prerender" }, { "Purpose" => "prefetch" } ].each do |headers|
      get company_path(slug: kairos.slug), headers: { "User-Agent" => BROWSER }.merge(headers)
      assert_response :success
    end

    assert_empty posthog.events
  end

  test "Turbo's hover prefetch is off, so every page opened reaches the server and counts once" do
    visit root_path

    assert_select 'meta[name="turbo-prefetch"][content="false"]'
  end

  test "a plant page sends power_plant_viewed with its slug" do
    vogtle = plant("Plant Vogtle", facility_type: "power_reactor")
    vogtle.evidence.create!(source: default_source, found_by: "human", confidence: 1)

    visit plant_path(slug: vogtle.slug)

    assert_response :success
    assert_equal [ [ "power_plant_viewed", vogtle.slug ] ], posthog.events.map { |e| [ e[:event], e[:properties]["slug"] ] }
  end

  test "a page that isn't found, or that moves, sends nothing" do
    visit company_path(slug: "no-such-company")
    assert_response :not_found

    kairos = cite!(company("Kairos Power"))
    old_slug = kairos.slug
    kairos.update!(name: "Kairos Power Co", slug: "kairos-power-co")
    FormerSlug.create!(sluggable: kairos, slug: old_slug) unless FormerSlug.exists?(slug: old_slug)
    visit company_path(slug: old_slug)
    assert_response :moved_permanently

    assert_empty posthog.events, "the page it moves to sends its own"
  end

  test "a correction sent sends correction_submitted with only what it's about" do
    post corrections_path, params: { subject: "Plant Vogtle", page_path: "/plants/vogtle", message: "Unit 4 started in 2024.",
      contact: "a@example.com" }, headers: { "User-Agent" => BROWSER }

    event = posthog.events.sole
    assert_equal [ "correction_submitted", "plant" ], [ event[:event], event[:properties]["subject_type"] ]
    assert_equal [ "/plants/vogtle", "Facility", facilities(:vogtle).id ],
      event[:properties].values_at("page_path", "record_type", "record_id"), "the page, and the company or plant on it"
    assert_nil event[:properties]["$ip"], "no IP"
    assert_not event[:properties].values.any? { |value| value.to_s.include?("Unit 4") || value.to_s.include?("a@example.com") },
      "never the message or contact"
  end

  test "a page address with a query or fragment is tracked by its path only; the report keeps it all" do
    post corrections_path, params: { subject: "Plant Vogtle", page_path: "/plants/vogtle?contact=reader@example.com#note", message: "Fix it." },
      headers: { "User-Agent" => BROWSER }

    event = posthog.events.sole
    assert_equal [ "/plants/vogtle", "Facility", facilities(:vogtle).id ], event[:properties].values_at("page_path", "record_type", "record_id")
    assert_not event[:properties].values.any? { |value| value.to_s.include?("reader@example.com") }
    assert_equal "/plants/vogtle?contact=reader@example.com#note", CorrectionReport.last.page_path
  end

  test "a directory search goes through the shared tracking: country added, bots skipped (#205)" do
    GeoCountry.reader, previous = FakeGeoReader.new, GeoCountry.reader
    get companies_path(q: "kairos"), headers: { "User-Agent" => BROWSER }, env: { "REMOTE_ADDR" => "81.2.69.142" }
    get companies_path(q: "kairos"), headers: { "User-Agent" => "Mozilla/5.0 (compatible; Googlebot/2.1)" }

    search = posthog.events.sole
    assert_equal [ "search", "kairos", "GB" ], [ search[:event], search[:properties]["query"], search[:properties]["$geoip_country_code"] ]
  ensure
    GeoCountry.reader = previous
  end

  test "a search from a home page suggestion says so; one typed in a field says typed" do
    get root_path, headers: { "User-Agent" => BROWSER }
    href = css_select(".nd-suggs a.nd-sugg").first["href"]
    words = Rack::Utils.parse_query(URI(href).query)["q"]
    query = words.downcase
    get href, headers: { "User-Agent" => BROWSER }
    get companies_path(q: words), headers: { "User-Agent" => BROWSER }

    searches = posthog.events.select { |event| event[:event] == "search" }
    assert_equal [ [ query, "suggestion" ], [ query, "typed" ] ], searches.map { |event| event[:properties].values_at("query", "source") }
  end

  test "filtering a suggested search keeps it a suggestion; a fresh search in the field is typed" do
    get companies_path(q: "HALEU", from: "suggestion"), headers: { "User-Agent" => BROWSER }
    assert_equal [ "suggestion" ], css_select("form.nd-filters input[name=from]").map { |input| input["value"] }

    params = css_select("form.nd-filters input[type=hidden]").to_h { |input| [ input["name"], input["value"] ] }
    get companies_path(params.merge(sort: "name")), headers: { "User-Agent" => BROWSER }
    get companies_path(q: "HALEU"), headers: { "User-Agent" => BROWSER }
    assert_empty css_select("form.nd-filters input[name=from]"), "a typed search carries no marker"

    sources = posthog.events.select { |event| event[:event] == "search" }.map { |event| event[:properties]["source"] }
    assert_equal %w[suggestion suggestion typed], sources
  end

  test "Show more on a search is the same search, expanded: one search event, not two" do
    get companies_path(q: "HALEU", from: "suggestion"), headers: { "User-Agent" => BROWSER }
    get companies_path(q: "HALEU", from: "suggestion", shown: 2), headers: { "User-Agent" => BROWSER }

    assert_equal 1, posthog.events.count { |event| event[:event] == "search" }
    assert_select "a[href*='shown=3']", count: 0
    assert_equal [ "suggestion" ], css_select("form.nd-filters input[name=from]").map { |input| input["value"] }, "the marker survives on the expanded page"
  end

  test "a correction that doesn't save sends nothing" do
    post corrections_path, params: { subject: "Plant Vogtle", page_path: "/plants/plant-vogtle", message: "" },
      headers: { "User-Agent" => BROWSER }

    assert_response :unprocessable_entity
    assert_empty posthog.events
  end
end
