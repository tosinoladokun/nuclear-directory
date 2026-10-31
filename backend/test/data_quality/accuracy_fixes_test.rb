require "test_helper"
require_relative "support/dummy_plugin"

# #533, #535, #554: three data-accuracy fixes.
class DataQuality::AccuracyFixesTest < ActiveSupport::TestCase
  BY = "human:tosin".freeze

  setup do
    @page = Source.create!(url: "https://www.nrc.gov/test/fixes.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "s",
      content_text: "GENERAL ATOMICS INC supplies the plant.")
  end

  test "#533: Same as… keeps the spelling as the company's other name, so the next claim matches it" do
    ga = Organization.create!(name: "General Atomics", verification_status: "verified", verified_by: BY)
    ga.aliases.create!(alias: "General Atomics")
    c = Candidate.create!(source: @page, kind: "organization", status: "needs_review", quote: "q",
      payload: { "name" => "GA Aeronautical Systems" }, notes: %(no exact match for "GA Aeronautical Systems"))
    assert_nil Directory::Lookup.organization(name: "GA Aeronautical Systems"), "it matches nothing before"
    assert DataQuality::Review.settle_company(c.id, end_key: nil, choice: "same", by: BY, record_id: ga.id).ok?
    assert_equal ga.id, Directory::Lookup.organization(name: "GA Aeronautical Systems")&.id
  end

  test "#554: an NRC unit named like an EIA site becomes a unit under it, keeping its docket" do
    site = Facility.create!(name: "Columbia", eia_plant_id: "371", verification_status: "verified", verified_by: BY)
    c = Candidate.create!(source: @page, kind: "facility", status: "new", quote: "q",
      payload: { "name" => "Columbia", "nrc_docket" => "05000397", "facility_type" => "power_reactor" })
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    unit = Facility.find_by!(nrc_docket: "05000397")
    assert_equal site.id, unit.parent_id
    assert_nil site.reload.nrc_docket, "the site keeps no docket"
    assert_equal unit.id, c.reload.subject_id

    again = Candidate.create!(source: @page, kind: "facility", status: "new", quote: "q",
      payload: { "name" => "Columbia", "nrc_docket" => "05000397", "facility_type" => "power_reactor" })
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_equal unit.id, again.reload.subject_id, "the next claim finds the unit by its docket"
    assert_equal 1, Facility.where(nrc_docket: "05000397").count
  end

  test "#535: approving a news claim keeps its news item, so a reread reconfirms the item's evidence" do
    company = Organization.create!(name: "News Fixes Co", verification_status: "verified", verified_by: BY)
    company.aliases.create!(alias: "News Fixes Co")
    c = Candidate.create!(source: @page, kind: "news_item", status: "matched", quote: "GENERAL ATOMICS INC supplies the plant.",
      subject_type: "Organization", subject_id: company.id,
      payload: { "url" => @page.url, "title" => "A news item", "published_on" => "2026-10-20", "summary" => "s",
        "about" => [ { "name" => "News Fixes Co", "type" => "organization" } ], "mentions" => [ [ "Organization", company.id ] ] })
    assert DataQuality::Review.approve([ c.id ], by: BY).sole.ok?
    item_id = c.reload.payload["news_item_id"]
    assert NewsItem.exists?(item_id)
    assert_equal [ "Organization", company.id ], c.values_at(:subject_type, :subject_id), "it stays on its company"

    run = CrawlRun.create!(stage: "extract", source_kind: "dummy")
    c.update_columns(crawl_run_id: run.id)
    read_at = 1.hour.ago
    @page.update!(fetched_at: read_at)
    DataQuality::Stages::Extract.new(plugin: DummyPlugin.new).send(:reconfirm, @page, "rows")
    evidence = Evidence.find_by!(subject_type: "NewsItem", subject_id: item_id, source: @page)
    assert_in_delta read_at, evidence.last_confirmed_at, 1.second
    assert_equal "rows", evidence.confirmed_sha256
  end
end
