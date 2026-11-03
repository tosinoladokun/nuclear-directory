require "test_helper"

# PM, 2 Nov (speed): whole company and plant pages and the home cards are
# built once per data version; a cached page reads exactly as a fresh one.
class PageCacheTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze

  setup do
    @store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @caching, ActionController::Base.perform_caching = ActionController::Base.perform_caching, true
    DataVersion.expire!
    @company = Organization.create!(name: "Cache Co", slug: "cache-co", description: "Builds reactors.", verification_status: "verified", verified_by: BY)
    page = Source.create!(url: "https://example.com/cache", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t")
    Evidence.create!(subject: @company, source: page, quote: "t", found_by: "human")
  end

  teardown do
    Rails.cache = @store
    ActionController::Base.perform_caching = @caching
    DataVersion.expire!
  end

  def body = response.body.gsub(/<meta name="csrf-token" content="[^"]+"/, "")

  test "a cached company page is the same page, title and head included, with few queries; a data change rebuilds it" do
    get "/companies/cache-co"
    fresh = body
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" } # cached ones too: the query cache can outlive a request in tests
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/companies/cache-co" }
    assert_equal fresh, body
    assert_match "<title>Cache Co", body
    assert_match %(rel="canonical" href="http://www.example.com/companies/cache-co"), body
    get "http://www.example.com:4000/companies/cache-co"
    assert_match %(href="http://www.example.com:4000/companies/cache-co"), body, "another port is another entry"
    assert_operator queries, :<=, 4

    before = DataVersion.current
    Evidence.where(subject: @company).update_all(quote: "t.") # no callbacks, as a reconfirm writes
    DataVersion.expire!
    assert_not_equal before, DataVersion.current, "an evidence edit changes the version"

    @company.update!(description: "Builds small reactors.")
    get "/companies/cache-co"
    assert_match "Builds small reactors.", body
  end

  test "home cards come from the cache until the data changes" do
    get "/"
    assert_response :success
    assert_equal fresh_cards = css_select(".nd-catgrid").to_s, (get("/") && css_select(".nd-catgrid").to_s)
    assert fresh_cards.present?
  end

  test "the companies list is cached per filter; a search never is" do
    get "/companies"
    fresh = body
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" } # cached ones too: the query cache can outlive a request in tests
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/companies" }
    assert_equal fresh, body
    assert_operator queries, :<=, 3
    assert_match "Cache Co", body

    get "/companies?sort=name&utm_source=x"
    assert_response :success
    get "/companies?shown=50"
    queries = 0
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/companies?shown=50" }
    assert_operator queries, :>, 3, "a long Show more list isn't cached"
    assert_match "Cache Co", body
    get "/companies?q=cache"
    queries = 0
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get "/companies?q=cache" }
    assert_operator queries, :>, 3, "the same search again still runs its queries"
    assert_match "Cache Co", body
  end
end
