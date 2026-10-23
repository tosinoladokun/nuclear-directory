require "test_helper"

# News items for "Latest" (#137): written through FactWriter, the same one by
# its link, public only once approved (Tosin, 21 Oct: approve each) and about
# a published company or plant; a unit's news is its site's; merges move it.
class NewsItemTest < ActiveSupport::TestCase
  BY = "human:tosin".freeze

  setup do
    @source = Source.create!(url: "https://www.world-nuclear-news.org/articles/x", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha")
    @company = Organization.create!(name: "Latest Fission Co").tap { |c| c.verify!(by: BY) }
  end

  def item(**attrs)
    result = Directory::FactWriter.write(:news_item, { url: "https://www.world-nuclear-news.org/articles/x", title: "Latest Fission Co files permit",
      publisher: "World Nuclear News", published_on: Date.new(2026, 10, 20), summary: "It filed a construction permit." }.merge(attrs),
      evidence: [ { source_id: @source.id, quote: "Latest Fission Co filed a construction permit.", found_by: "human" } ],
      verification: { status: "pending", by: BY, reason: "Added by hand" })
    assert result.ok?, result.errors.inspect
    NewsItem.find(result.id)
  end

  test "the same item by its link; a person approves it before it's public" do
    first = item
    again = item(title: "Latest Fission Co files permit (updated)")
    assert_equal first.id, again.id
    Directory::FactWriter.mention_news(news_item_id: first.id, subject_type: "Organization", subject_id: @company.id)

    assert_empty NewsItem.published
    assert_empty Directory::Lookup.latest_news(type: "Organization", id: @company.id)

    first.verify!(by: BY)
    assert_equal [ "Latest Fission Co files permit (updated)" ], Directory::Lookup.latest_news(type: "Organization", id: @company.id).map(&:title)
  end

  test "public only about a published company or plant; newest first" do
    old = item(url: "https://example.com/old", published_on: Date.new(2026, 9, 1)).tap { |n| n.verify!(by: BY) }
    new = item(url: "https://example.com/new", published_on: Date.new(2026, 10, 1)).tap { |n| n.verify!(by: BY) }
    [ old, new ].each { |n| Directory::FactWriter.mention_news(news_item_id: n.id, subject_type: "Organization", subject_id: @company.id) }
    assert_equal [ new.id, old.id ], NewsItem.latest_for(@company).ids

    @company.unpublish!(by: BY, reason: "Not nuclear")
    assert_empty NewsItem.published
  end

  test "a unit's news is its site's" do
    site = Facility.create!(name: "Latest Point").tap { |f| f.verify!(by: BY) }
    unit = Facility.create!(name: "Latest Point 1", parent: site)
    news = item.tap { |n| n.verify!(by: BY) }
    mention = Directory::FactWriter.mention_news(news_item_id: news.id, subject_type: "Facility", subject_id: unit.id)
    assert_equal site, mention.subject
    assert_equal [ news.id ], Directory::Lookup.latest_news(type: "Facility", id: unit.id).map(&:id)
  end

  test "a merge moves a company's news to the one kept, once" do
    other = Organization.create!(name: "Latest Fission Company").tap { |c| c.verify!(by: BY) }
    news = item.tap { |n| n.verify!(by: BY) }
    [ @company, other ].each { |c| Directory::FactWriter.mention_news(news_item_id: news.id, subject_type: "Organization", subject_id: c.id) }
    second = item(url: "https://example.com/second").tap { |n| n.verify!(by: BY) }
    Directory::FactWriter.mention_news(news_item_id: second.id, subject_type: "Organization", subject_id: other.id)

    Directory::FactWriter.merge_organization(from_id: other.id, into_id: @company.id, by: BY, reason: "Same company")
    assert_equal [ news.id, second.id ].sort, NewsMention.where(subject: @company).pluck(:news_item_id).sort
    assert_empty NewsMention.where(subject: other)
  end

  test "a link that isn't a web address, or a missing headline or date, is refused" do
    result = Directory::FactWriter.write(:news_item, { url: "ftp://x", title: "", published_on: nil }, verification: { status: "pending", by: BY })
    assert_not result.ok?
  end

  test "an item an agent verified isn't public: a person approves each" do
    news = item.tap { |n| n.verify!(by: "agent:verifier/model") }
    Directory::FactWriter.mention_news(news_item_id: news.id, subject_type: "Organization", subject_id: @company.id)
    assert_empty NewsItem.published
  end

  test "news on a standalone unit moves to its site when the unit gains one" do
    unit = Facility.create!(name: "Lone Unit 1").tap { |f| f.verify!(by: BY) }
    news = item.tap { |n| n.verify!(by: BY) }
    Directory::FactWriter.mention_news(news_item_id: news.id, subject_type: "Facility", subject_id: unit.id)
    site = Facility.create!(name: "Lone Point").tap { |f| f.verify!(by: BY) }

    assert Directory::FactWriter.write(:facility, { id: unit.id, parent_id: site.id }, fill_blank: true).ok?
    assert_equal [ [ "Facility", site.id ] ], NewsMention.where(news_item: news).pluck(:subject_type, :subject_id)
    assert_equal [ news.id ], Directory::Lookup.latest_news(type: "Facility", id: unit.id).map(&:id)
    assert_equal [ news.id ], Directory::Lookup.latest_news(type: "Facility", id: site.id).map(&:id)
  end
end
