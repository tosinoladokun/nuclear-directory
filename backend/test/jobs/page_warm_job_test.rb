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

  test "a change rebuilds only the pages it touched" do
    other = Organization.create!(name: "Other Warm Co", slug: "other-warm-co", description: "Makes fuel.", verification_status: "verified", verified_by: BY)
    Evidence.create!(subject: other, source: Source.first, quote: "t", found_by: "human")
    PageWarmJob.perform_now(pause: 0, debounce: false)

    # A change only this page reads: its own quote (any company change rebuilds every company page, for Similar companies).
    Evidence.where(subject: Organization.find_by!(slug: "warm-co")).update_all(quote: "Builds small reactors.")
    DataVersion.expire!
    drawn = []
    counter = ->(*, payload) { drawn << payload[:identifier].to_s[%r{views/(\w+/\w+)}, 1] }
    ActiveSupport::Notifications.subscribed(counter, "render_template.action_view") { PageWarmJob.perform_now(pause: 0, debounce: false) }
    assert_equal [ "companies/show" ], drawn.compact.uniq.reject { |name| name == "home/show" }
    assert_equal 1, drawn.count("companies/show"), "the other company's page is still current"
    assert_operator queries_for("/companies/other-warm-co"), :<=, 4
  end

  def stamp_queries
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].to_s.include?("md5(concat_ws") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "stamps are computed once per data change, never on a visit or a quiet tick (Infra)" do
    assert_match %r{\Adata/}, PageStamps.version(:company, Organization.find_by!(slug: "warm-co").id), "no map yet: the directory's version stands in"
    assert_operator stamp_queries { PageWarmJob.perform_now(pause: 0, debounce: false) }, :>, 0
    assert_equal 0, stamp_queries { get "/companies/warm-co" }, "a visit reads its version from the map"
    assert_response :success
    assert_equal 0, stamp_queries { PageWarmJob.perform_now(pause: 0) }, "nothing changed: no stamps"
  end

  test "a map the cache dropped is rebuilt on the next tick; a commit moves the data version even if MAX(updated_at) doesn't" do
    PageWarmJob.perform_now(pause: 0, debounce: false)
    data = DataVersion.current
    Rails.cache.delete([ PageStamps::MAP, data ])
    assert_operator stamp_queries { PageWarmJob.perform_now(pause: 0, debounce: false) }, :>, 0
    assert Rails.cache.exist?([ PageStamps::MAP, data ])

    company = Organization.find_by!(slug: "warm-co")
    company.update_columns(updated_at: 1.year.ago) # an older timestamp: the aggregates alone wouldn't move
    DirectorySnapshot.expire! # what the commit callback does
    assert_not_equal data, DataVersion.current
  end
end
