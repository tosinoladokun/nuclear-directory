require "test_helper"

# PM, 3 Nov: cached pages are built in the background after a data change,
# so a visitor's first view is already cached.
class PageWarmJobTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze

  setup do
    @store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @caching, ActionController::Base.perform_caching = ActionController::Base.perform_caching, true
    @host, ENV["WARM_HOST"] = ENV["WARM_HOST"], "www.example.com"
    DataVersion.expire!
    company = Organization.create!(name: "Warm Co", slug: "warm-co", description: "Builds reactors.", verification_status: "verified", verified_by: BY)
    page = Source.create!(url: "https://example.com/warm", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t")
    Evidence.create!(subject: company, source: page, quote: "t", found_by: "human")
    https!
  end

  teardown do
    Rails.cache = @store
    ActionController::Base.perform_caching = @caching
    ENV["WARM_HOST"] = @host
    DataVersion.expire!
  end

  def queries_for(path)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get path }
    count
  end

  def without_token(body) = body.gsub(/<meta name="csrf-token" content="[^"]+"/, "")

  test "after a run, a company page's first view comes from the cache and matches a fresh build; a run with no change does nothing" do
    PageWarmJob.perform_now(pause: 0, debounce: false)
    assert_operator queries_for("/companies/warm-co"), :<=, 4
    warmed = without_token(response.body)
    Rails.cache.clear
    get "/companies/warm-co"
    assert_equal without_token(response.body), warmed

    PageWarmJob.perform_now(pause: 0, debounce: false)
    rendered = 0
    counter = ->(*) { rendered += 1 }
    ActiveSupport::Notifications.subscribed(counter, "render_template.action_view") { PageWarmJob.perform_now(pause: 0, debounce: false) }
    assert_equal 0, rendered, "nothing changed, nothing rebuilt"
  end

  test "debounced: the first tick after a change only notes it; the next, with nothing new, warms" do
    rendered = 0
    counter = ->(*) { rendered += 1 }
    ActiveSupport::Notifications.subscribed(counter, "render_template.action_view") { PageWarmJob.perform_now(pause: 0) }
    assert_equal 0, rendered, "just changed: wait a tick"
    ActiveSupport::Notifications.subscribed(counter, "render_template.action_view") { PageWarmJob.perform_now(pause: 0) }
    assert_operator rendered, :>, 0, "quiet since the last tick: warm"
  end
end
