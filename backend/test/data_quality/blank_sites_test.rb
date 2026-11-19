require "test_helper"

class DataQuality::BlankSitesTest < ActiveSupport::TestCase
  def company(name, website, **source)
    Organization.create!(name:, website:, verification_status: "verified", verified_by: "human:tosin")
    Source.create!(url: website, source_kind: "company_pages", fetched_at: Time.zone.parse("2026-11-18 03:00"), **source)
  end

  test "lists blocked, unreadable, empty and JavaScript-only home pages, with company, address, reason and date" do
    company("Blocked Fission", "https://blocked.example", crawl_status: "blocked")
    company("Broken Fission", "https://broken.example", crawl_status: "needs_human")
    company("Empty Fission", "https://empty.example", crawl_status: "ok", content_text: "")
    company("Script Fission", "https://script.example", crawl_status: "ok", content_text: "<html><body><div id=root></div><script>x()</script></body></html>")
    company("Fine Fission", "https://fine.example", crawl_status: "ok", content_text: "We build reactors. " * 60)
    company("Waiting Fission", "https://waiting.example")

    sites = DataQuality::BlankSites.list
    assert_equal [ "Blocked Fission", "Broken Fission", "Empty Fission", "Script Fission" ], sites.map(&:company)
    assert_equal DataQuality::BlankSites::REASONS["js_only"], sites.last.reason
    assert_equal [ "https://script.example", Date.new(2026, 11, 18) ], [ sites.last.url, sites.last.checked_on ]
    assert_equal 4, DataQuality::BlankSites.count
  end
end
