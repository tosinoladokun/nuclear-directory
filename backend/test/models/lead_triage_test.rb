require "test_helper"

# Tosin, 27 Oct: "people are searching rubbish, it should be on triage".
class LeadTriageTest < ActiveSupport::TestCase
  def gap(query, count = 1) = SearchGap.create!(query:, searches_count: count, first_searched_on: Date.current, last_searched_on: Date.current)

  test "junk never becomes a lead: too short, addresses, gibberish, profanity, names we have" do
    %w[ab 1234 http://x.com a@b.co xkcdqwrt aaaaaa shit].each { |query| assert Lead.junk?(query), query }
    assert_not Lead.junk?("Blue Energy")
    Organization.create!(name: "Known Fission", verification_status: "verified", verified_by: "human:tosin").aliases.create!(alias: "Known Fission")
    gap("known fission")
    gap("qwrtzxpl")
    LeadSync.run
    assert_equal 0, Lead.count
  end

  test "a searched name waits in triage, and moves to To do after 3 searches or when a source names it too" do
    gap("Blue Energy")
    LeadSync.run
    lead = Lead.sole
    assert lead.status_triage?
    SearchGap.sole.update!(searches_count: 3)
    LeadSync.run
    assert lead.reload.status_new?, "searched 3 times"

    gap("Copenhagen Atomics")
    LeadSync.run
    other = Lead.find_by!(normalized_name: "copenhagen atomics")
    assert other.status_triage?
    Lead.sighted!(name: "Copenhagen Atomics", kind: "other", key: "news:x", label: "News")
    assert other.reload.status_new?, "a source named it too"
  end

  test "trade-press headlines don't become leads" do
    page = Source.create!(url: "https://example.com/press", source_kind: "trade_press", crawl_status: "ok", content_sha256: "p")
    Candidate.create!(source: page, kind: "news_item", status: "new", quote: "q",
      payload: { "title" => "Oklo plans isotope facility", "lead" => true, "publisher" => "Press" })
    LeadSync.run
    assert_equal 0, Lead.count
  end

  test "the data step moves search-only leads to triage and sets headlines aside, keeping the rest" do
    searched = Lead.sighted!(name: "Old Search", kind: "other", key: "search:1", label: "Search").tap { |l| l.update_columns(status: "new") }
    headline = Lead.sighted!(name: "Oklo plans isotope facility", kind: "other", key: "trade_press:9", label: "Trade press").tap { |l| l.update_columns(status: "new") }
    mixed = Lead.sighted!(name: "Mixed Co", kind: "company", key: "search:2", label: "Search")
    Lead.sighted!(name: "Mixed Co", kind: "company", key: "news:5", label: "News")
    researching = Lead.sighted!(name: "Busy Co", kind: "company", key: "search:3", label: "Search").tap { |l| l.update_columns(status: "researching") }
    require Rails.root.join("db/migrate/20261027180000_add_triage_to_leads")
    AddTriageToLeads.new.tap { |m| m.verbose = false }.migrate(:up)
    assert_equal %w[triage ignored new researching], [ searched, headline, mixed, researching ].map { |lead| lead.reload.status }
    assert_match "A headline, not a name", headline.reason
  end
end
