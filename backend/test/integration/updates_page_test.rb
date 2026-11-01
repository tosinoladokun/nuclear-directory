require "test_helper"

# The /updates page (PM, 31 Oct): the same entries as the Atom feed, as a page people can read and link to.
class UpdatesPageTest < ActionDispatch::IntegrationTest
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

  test "the page lists the entries newest first, each linking to its page, with the source domain as a link out" do
    get updates_path
    assert_response :success
    assert_select "head > title", "What's new: newly approved facts, deals and news | Nuclear Directory"
    assert_select "link[rel=canonical][href=?]", updates_url
    assert_select "head link[rel=alternate][type='application/atom+xml'][href=?]", updates_feed_url
    assert_equal [ "Feed Vendor permit", "Feed Buyer offtakes from Feed Vendor", "New company: Feed Vendor" ], css_select(".nd-updates .nd-news__title").map { |node| node.text.strip }
    assert_select ".nd-updates .nd-news__title a[href=?]", company_path(slug: "feed-vendor"), minimum: 1
    assert_select ".nd-updates a.nd-news__src[href='https://www.federalregister.gov/d/2026-9'][rel~=noopener][target=_blank]", /federalregister\.gov/
    assert_select ".nd-news__date", count: 3
    assert_select "a[href=?]", updates_feed_path, /Atom feed/
  end

  test "nothing internal or unpublished shows, and the sitemap lists the page" do
    get updates_path
    assert_select "body", text: /internal note|Pending Co|agent:dq/, count: 0

    get sitemap_path
    assert_includes response.body, "<loc>#{updates_url}</loc>"
  end

  test "an empty feed says so" do
    VerificationEvent.delete_all
    get updates_path
    assert_response :success
    assert_select ".nd-updates", 0
    assert_select "main", /Nothing has been added yet/
  end

  test "the HTML is private (only the entries are cached), and a source URL URI can't parse still names its publisher, unlinked" do
    @news.update_columns(url: "https://www.example.org/café")
    Rails.cache.delete("updates_page_entries")
    get updates_path
    assert_response :success
    assert_no_match(/public/, response.headers["Cache-Control"].to_s)
    assert_select ".nd-updates span.nd-news__src", "example.org"
    assert_select ".nd-updates a.nd-news__src[href*='example.org']", count: 0
  end
end
