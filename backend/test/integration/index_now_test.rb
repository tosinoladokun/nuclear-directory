require "test_helper"

# IndexNow (#742): changed public pages go to the engines in one batch, at
# most every ten minutes, never a disallowed path; the key file proves it.
class IndexNowTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze
  KEY = "a1b2c3d4e5f6a7b8".freeze

  setup do
    @store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @env, ENV["INDEXNOW_KEY"] = ENV["INDEXNOW_KEY"], KEY
    @sender = IndexNow.sender
    @sent = []
    IndexNow.sender = ->(uri, json) { @sent << [ uri.to_s, JSON.parse(json) ]; true }
    @company = Organization.create!(name: "Ping Co", slug: "ping-co", verification_status: "verified", verified_by: BY)
    @other = Organization.create!(name: "Quiet Co", slug: "quiet-co", verification_status: "verified", verified_by: BY)
  end

  teardown do
    Rails.cache = @store
    ENV["INDEXNOW_KEY"] = @env
    IndexNow.sender = @sender
  end

  def map(company: {}) = { company: { @company.id => "rev/2026-11-09/a", @other.id => "rev/2026-11-09/b" }.merge(company), plant: {} }

  test "a changed company's page, the lists and /updates go in one batch; an unchanged company and disallowed paths don't" do
    IndexNow.note_changes(map, host: "nuclear-directory.org")
    assert IndexNow.flush(host: "nuclear-directory.org")
    first = @sent.sole.last
    assert_equal [ "nuclear-directory.org", KEY, "https://nuclear-directory.org/#{KEY}.txt" ], first.values_at("host", "key", "keyLocation")
    assert_includes first["urlList"], "https://nuclear-directory.org/companies/quiet-co", "the first batch has every page"

    travel 11.minutes do
      IndexNow.note_changes(map(company: { @company.id => "rev/2026-11-10/changed" }), host: "nuclear-directory.org")
      assert IndexNow.flush(host: "nuclear-directory.org")
    end
    urls = @sent.last.last["urlList"]
    assert_includes urls, "https://nuclear-directory.org/companies/ping-co"
    assert_includes urls, "https://nuclear-directory.org/companies"
    assert_includes urls, "https://nuclear-directory.org/updates"
    assert_not_includes urls, "https://nuclear-directory.org/companies/quiet-co"
    assert urls.none? { |url| url.match?(%r{\.org/(admin|corrections|search|design)(/|\?|\z)}) }
  end

  test "only the date or deploy moving isn't a change; batches wait ten minutes; a failure is tried once more, then dropped" do
    IndexNow.note_changes(map, host: "nuclear-directory.org")
    IndexNow.flush(host: "nuclear-directory.org")
    IndexNow.note_changes({ company: { @company.id => "rev2/2026-11-10/a", @other.id => "rev2/2026-11-10/b" }, plant: {} }, host: "nuclear-directory.org")
    assert_nil Rails.cache.read(IndexNow::PENDING), "same stamps: nothing to send"

    IndexNow.note_changes(map(company: { @company.id => "rev/2026-11-09/new" }), host: "nuclear-directory.org")
    assert_nil IndexNow.flush(host: "nuclear-directory.org"), "a batch went less than ten minutes ago"
    tries = 0
    IndexNow.sender = ->(*) { tries += 1; false }
    travel 11.minutes do
      assert_equal false, IndexNow.flush(host: "nuclear-directory.org")
    end
    assert_equal 2, tries
    assert_nil Rails.cache.read(IndexNow::PENDING)
  end

  test "off without a key; the key file is served only for the key" do
    get "/#{KEY}.txt"
    assert_response :success
    assert_equal KEY, response.body
    get "/abcdefgh12345678.txt"
    assert_response :not_found
    get "/robots.txt"
    assert_response :success

    ENV["INDEXNOW_KEY"] = nil
    IndexNow.note_changes(map, host: "nuclear-directory.org")
    assert_nil IndexNow.flush(host: "nuclear-directory.org")
    assert_empty @sent
  end
end
