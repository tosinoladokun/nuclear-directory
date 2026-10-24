require "test_helper"

class LeadSyncTest < ActiveSupport::TestCase
  setup do
    @page = Source.create!(url: "https://example.com/news/a", source_kind: "company_newsrooms", crawl_status: "ok")
  end

  test "brings in searches, unmatched news, trade press, Enrich's unknown companies and waiting award recipients, and again changes nothing" do
    SearchGap.create!(query: "zentra fusion", searches_count: 4, first_searched_on: Date.new(2026, 10, 1), last_searched_on: Date.new(2026, 10, 3), status: "open")
    Candidate.create!(source: @page, kind: "news_item", status: "needs_review", quote: "q", notes: "it names no company or plant in the directory",
      payload: { "url" => @page.url, "title" => "Nova Reactors raises funds", "about" => [ { "name" => "Nova Reactors", "type" => "organization" } ] })
    Candidate.create!(source: @page, kind: "news_item", status: "needs_review", quote: "q", notes: "lead",
      payload: { "url" => "https://www.world-nuclear-news.org/x", "title" => "A trade-press headline", "publisher" => "World Nuclear News", "lead" => true, "about" => [] })
    site = Source.create!(url: "https://acme.example.com/about", source_kind: "company_pages", crawl_status: "ok")
    Candidate.create!(source: site, kind: "relationship", status: "needs_review", quote: "q",
      payload: { "from_organization" => { "name" => "Acme" }, "to_organization" => { "name" => "Quillon Grid" }, "relationship_type" => "supplies" },
      notes: %(to_organization "Quillon Grid" isn't in the directory yet))
    Source.create!(url: "https://api.usaspending.gov/x#r1", source_kind: "usaspending_doe_awards", crawl_status: "ok",
      content_text: "award_id,recipient_name\nA1,NEW SBIR CO LLC\n")

    LeadSync.run
    assert_equal [ [ "other", "zentra fusion", 4 ], [ "company", "Nova Reactors", 1 ], [ "other", "A trade-press headline", 1 ],
      [ "company", "Quillon Grid", 1 ], [ "company", "NEW SBIR CO LLC", 1 ] ].sort, Lead.pluck(:kind, :name, :seen_count).sort
    assert_no_difference -> { Lead.sum(:seen_count) } do
      LeadSync.run
    end
  end
end
