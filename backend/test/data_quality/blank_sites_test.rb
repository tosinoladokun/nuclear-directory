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

    company("Data Fission", "https://data.example", crawl_status: "ok",
      content_text: "<html><head><meta name=description content='#{"We build microreactors for remote sites. " * 20}'></head><body></body></html>")
    company("Timeout Fission", "https://timeout.example", crawl_status: "ok", content_text: "We build reactors. " * 60, status_reason: "Timed out")
    company("First Fail Fission", "https://firstfail.example", status_reason: "Timed out")
    company("Robots Fission", "https://robots.example", crawl_status: "needs_human", status_reason: "robots.txt disallows us")
    Organization.create!(name: "Sister Fission", website: "https://blocked.example", verification_status: "verified", verified_by: "human:tosin")
    Organization.create!(name: "Path Fission", website: "https://fine.example/company", verification_status: "verified", verified_by: "human:tosin")
    Source.create!(url: "https://fine.example/company/", source_kind: "web_page", crawl_status: "blocked", fetched_at: Time.current)
    Source.find_by!(url: "https://blocked.example").update!(source_kind: "web_page")

    sites = DataQuality::BlankSites.list
    by = sites.to_h { |site| [ site.company, site.reason ] }
    reasons = DataQuality::BlankSites::REASONS
    assert_equal({ "Blocked Fission" => reasons["blocked"], "Broken Fission" => reasons["unreadable"], "Empty Fission" => reasons["empty"],
      "First Fail Fission" => reasons["unreadable"], "Robots Fission" => reasons["blocked"], "Script Fission" => reasons["js_only"],
      "Sister Fission" => reasons["blocked"], "Timeout Fission" => reasons["unreadable"] }, by,
      "page data counts; any source kind; shared sites list each company; a path site isn't matched by its slash form")
    script = sites.find { |site| site.company == "Script Fission" }
    assert_equal [ "https://script.example", Date.new(2026, 11, 18) ], [ script.url, script.checked_on ]
    assert_equal 8, DataQuality::BlankSites.count
  end
end
