require "test_helper"

# What's new (PM, 31 Oct): newly approved public facts, deals and news, newest first.
class UpdatesFeedTest < ActionDispatch::IntegrationTest
  BY = "human:tosin".freeze

  def approve(record, at:, by: BY, from: "pending")
    VerificationEvent.create!(subject: record, from_status: from, to_status: "verified", by:, reason: "internal note", created_at: at)
  end

  setup do
    @vendor = Organization.create!(name: "Feed Vendor", slug: "feed-vendor", verification_status: "verified", verified_by: BY)
    @buyer = Organization.create!(name: "Feed Buyer", slug: "feed-buyer", verification_status: "verified", verified_by: BY)
    page = Source.create!(url: "https://example.com/deal", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "t")
    @link = Relationship.create!(from_organization: @buyer, to_organization: @vendor, relationship_type: "offtake_with", verification_status: "verified", verified_by: BY)
    Evidence.create!(subject: @link, source: page, quote: "t", found_by: "human")
    @news = NewsItem.create!(url: "https://www.federalregister.gov/d/2026-9", title: "Long docket title", headline: "Feed Vendor permit",
      published_on: Date.current, summary: "The NRC issued a permit.", verification_status: "verified", verified_by: BY)
    @news.news_mentions.create!(subject: @vendor)
    @hidden = Organization.create!(name: "Pending Co", slug: "pending-co", verification_status: "pending")

    VerificationEvent.delete_all # the ones written on create; these tests set their own
    approve(@vendor, at: 3.days.ago)
    approve(@vendor, at: 1.hour.ago, from: "unpublished") # approved again: listed once, at its first approval
    approve(@link, at: 2.days.ago)
    approve(@news, at: 1.day.ago)
    approve(@buyer, at: 4.days.ago, by: "agent:dq") # not a person's approval
    approve(@hidden, at: 1.day.ago)                 # not public now
  end

  test "entries: each published fact once, at a person's first approval, newest first, with its page and source" do
    entries = Updates.new.entries
    assert_equal [ "Feed Vendor permit", "Feed Buyer offtakes from Feed Vendor", "New company: Feed Vendor" ], entries.map(&:title)
    news, link, _ = entries
    assert_equal [ :company, "feed-vendor" ], news.page
    assert_equal "https://www.federalregister.gov/d/2026-9", news.source_url
    assert_equal "https://example.com/deal", link.source_url
    assert_equal %w[news fact new_record], entries.map(&:kind)
  end

  test "the Atom feed lists them with links to the pages and sources, and nothing internal" do
    get updates_feed_path
    assert_response :success
    assert_equal "application/atom+xml", response.media_type
    feed = Nokogiri::XML(response.body).remove_namespaces!
    assert_equal [ "Feed Vendor permit", "Feed Buyer offtakes from Feed Vendor", "New company: Feed Vendor" ], feed.xpath("//entry/title").map(&:text)
    assert_includes feed.xpath("//entry/link[@rel='alternate']/@href").map(&:value), company_url(slug: "feed-buyer")
    assert_includes feed.xpath("//entry/link[@rel='related']/@href").map(&:value), "https://example.com/deal"
    assert_no_match(/internal note|human:|agent:|Pending Co/, response.body)
  end

  test "the feed is built once an hour and sends no session cookie" do
    store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    begin
      get updates_feed_path
      first = response.body
      Organization.create!(name: "Later Co", slug: "later-co", verification_status: "verified", verified_by: BY)
      get updates_feed_path
      assert_equal first, response.body, "served from the cache"
      assert_nil response.headers["Set-Cookie"]
      assert_match "public", response.headers["Cache-Control"]
      Rails.cache.clear
      get updates_feed_path
      assert_match "New company: Later Co", response.body
    ensure
      Rails.cache = store
    end
  end

  test "awards carry amount and date; roles read as a sentence; at most 5 of one kind a day" do
    VerificationEvent.delete_all
    doe = Organization.create!(name: "DOE", slug: "doe", verification_status: "verified", verified_by: BY)
    funds = Relationship.create!(from_organization: doe, to_organization: @vendor, relationship_type: "funds", verification_status: "verified", verified_by: BY)
    award = DealTerm.create!(link: funds, term_type: "award", amount_usd: 12_500_000, starts_on: Date.new(2026, 9, 1), external_id: "A-1",
      verification_status: "verified", verified_by: BY)
    role = OrganizationRole.create!(organization: doe, role: Role.find_or_create_by!(key: "government_agency") { |r| r.name = "Government agency" },
      verification_status: "verified", verified_by: BY)
    plants = 7.times.map { |n| Facility.create!(name: "Feed Plant #{n}", slug: "feed-plant-#{n}", facility_type: "power_reactor", verification_status: "verified", verified_by: BY) }
    links = plants.map { |plant| FacilityRelationship.create!(organization: @vendor, facility: plant, relationship_type: "vendor_for", verification_status: "verified", verified_by: BY) }
    VerificationEvent.delete_all
    [ award, role, *links ].each { |record| approve(record, at: 2.hours.ago) }

    titles = Updates.new.entries.map(&:title)
    assert_includes titles, "Award ($12.5 million, Sep 2026): DOE funds Feed Vendor"
    assert_includes titles, "DOE is now listed under Government agency"
    assert_equal 5, titles.grep(/is the reactor developer for/).size
  end

  test "hidden approvals beyond a batch don't hide older public ones; a news item goes to its public page; a deal says its form and stage" do
    hidden = 3.times.map { |n| Organization.create!(name: "Gone #{n}", slug: "gone-#{n}", verification_status: "pending") }
    hidden.each { |org| approve(org, at: 1.minute.ago) }
    gone = Organization.create!(name: "Gone Co", slug: "gone-co", verification_status: "pending")
    @news.news_mentions.create!(subject: gone)
    assert_equal "New company: Feed Vendor", Updates.new.entries(limit: 3, batch: 2).last.title
    assert_equal [ :company, "feed-vendor" ], Updates.new.entries.find { |e| e.kind == "news" }.page

    deal = DealTerm.create!(link: @link, term_type: "offtake", agreement: "mou", status: "announced", capacity_mw: 50, signed_on: Date.new(2026, 8, 1),
      verification_status: "verified", verified_by: BY)
    approve(deal, at: 1.minute.ago)
    assert_equal "Power deal (MOU, announced, Aug 2026): Feed Buyer offtakes from Feed Vendor", Updates.new.entries.first.title
  end

  test "a few queries per batch, not per entry" do
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { Updates.new.entries }
    assert_operator queries, :<, 25
  end
end
