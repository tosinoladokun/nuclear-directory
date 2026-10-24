require "test_helper"
require_relative "support/dummy_plugin"

# News items as claims (#137 part B): matched to the companies and plants
# they name, approved by a person (Tosin, 21 Oct: approve each), and only
# then in "Latest".
class DataQuality::NewsClaimsTest < ActiveSupport::TestCase
  BY = "human:tosin".freeze

  setup do
    @source = Source.create!(url: "https://www.world-nuclear-news.org/articles/acme", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: "Acme Fission files for a construction permit at Latest Point.")
    @company = Organization.create!(name: "Acme Fission").tap { |c| c.verify!(by: BY); c.aliases.create!(alias: c.name) }
    @site = Facility.create!(name: "Latest Point").tap { |f| f.verify!(by: BY) }
  end

  def news(about)
    Candidate.create!(source: @source, kind: "news_item", quote: "Acme Fission files for a construction permit at Latest Point.",
      payload: { "url" => @source.url, "title" => "Acme Fission files permit", "publisher" => "World Nuclear News", "published_on" => "2026-10-20",
        "summary" => "Acme Fission filed a construction permit application.", "about" => about })
  end

  def match! = DataQuality::Stages::Match.call(plugin: DummyPlugin.new)

  test "match notes every company and plant it names and attaches the first; one naming nothing waits for a person" do
    found = news([ { "name" => "Acme Fission", "type" => "organization" }, { "name" => "Latest Point", "type" => "facility" } ])
    lost = news([ { "name" => "Nobody Fission", "type" => "organization" } ])
    match!

    found.reload
    assert_equal [ "matched", "Organization", @company.id ], [ found.status, found.subject_type, found.subject_id ]
    assert_equal [ [ "Organization", @company.id ], [ "Facility", @site.id ] ], found.payload["mentions"]
    assert_equal "needs_review", lost.reload.status
    assert_match "names no company or plant in the directory", lost.notes
  end

  test "approving writes the item and its mentions; it shows in Latest only once approved, and the claim stays on its company" do
    claim = news([ { "name" => "Acme Fission", "type" => "organization" }, { "name" => "Latest Point", "type" => "facility" } ])
    match!
    assert_empty Directory::Lookup.latest_news(type: "Organization", id: @company.id)

    result = DataQuality::Review.approve([ claim.id ], by: BY).sole
    assert result.ok?, result.errors.inspect
    item = NewsItem.sole
    assert_equal [ "Acme Fission files permit", Date.new(2026, 10, 20), "verified" ], [ item.title, item.published_on, item.verification_status ]
    assert_equal [ @company.id ], Directory::Lookup.latest_news(type: "Organization", id: @company.id).map { |n| NewsItem.find(n.id).news_mentions.where(subject_type: "Organization").pick(:subject_id) }
    assert_equal [ item.id ], Directory::Lookup.latest_news(type: "Facility", id: @site.id).map(&:id)
    assert_equal [ "merged", "Organization", @company.id ], claim.reload.values_at(:status, :subject_type, :subject_id)
  end

  test "it reads in plain words" do
    claim = news([ { "name" => "Acme Fission", "type" => "organization" } ])
    assert_equal "News: “Acme Fission files permit” (World Nuclear News, 2026-10-20), about Acme Fission. " \
      "Summary: “Acme Fission filed a construction permit application.”", DataQuality::Claim.describe(claim)
  end

  test "approving news about nothing in the directory, or about a company taken off since, is refused without stopping the batch" do
    loose = Candidate.create!(source: @source, kind: "news_item", quote: "Someone else files permit", status: "needs_review",
      payload: { "url" => "https://example.com/elsewhere", "title" => "Someone else files permit", "about" => [] })
    result = DataQuality::Review.approve([ loose.id ], by: BY).sole
    assert_not result.ok?
    assert_match "isn't about a company or plant in the directory yet", result.errors.to_sentence

    claim = news([ { "name" => "Acme Fission", "type" => "organization" } ])
    match!
    @company.update_columns(verification_status: "rejected", verified_by: BY)
    result = DataQuality::Review.approve([ claim.reload.id ], by: BY).sole
    assert_not result.ok?
    assert_empty NewsItem.all, "item and mentions together, or neither"
  end
end
