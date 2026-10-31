require "test_helper"

class Directory::GapFillTest < ActiveSupport::TestCase
  setup do
    Organization.update_all(enrich_requested_at: Time.current, enriched_at: Time.current)
    @role = Role.create!(key: "gap_fill_test", name: "Gap fill test")
  end

  def company(name, role: true, **attributes)
    Organization.create!(name:, verification_status: "verified", verified_by: "human:tosin", **attributes).tap do |org|
      OrganizationRole.create!(organization: org, role: @role).verify!(by: "human:tosin") if role
    end
  end

  test "asks Enrich for published, categorised companies missing HQ or description, most missing first; lists those without a website" do
    bare = company("Bare Fission", website: "https://bare.example")
    half = company("Half Fission", website: "https://half.example", description: "Builds reactors.")
    full = company("Full Fission", website: "https://full.example", description: "x", hq_city: "Austin", hq_state: "TX")
    uncategorised = company("Loose Fission", role: false, website: "https://loose.example")
    company("Siteless Fission")
    pending = Organization.create!(name: "Pending Fission", website: "https://pending.example")

    company("Broken Site Fission", website: "https://bad host")
    first = Directory::Lookup.request_gap_fill(limit: 1)
    assert_equal 1, first[:requested]
    assert_equal [ "Broken Site Fission", "Siteless Fission" ], first[:without_website], "missing or unreadable websites, for Data Quality"
    assert bare.reload.enrich_requested_at, "most gaps first"
    assert_nil half.reload.enrich_requested_at

    Directory::Lookup.request_gap_fill(limit: 5)
    assert half.reload.enrich_requested_at
    assert_nil full.reload.enrich_requested_at, "no gaps, nothing to read"
    assert_nil uncategorised.reload.enrich_requested_at, "category is Data Quality's, by hand"
    assert_nil pending.reload.enrich_requested_at, "unpublished companies aren't filled"
    requested = bare.reload.enrich_requested_at
    Directory::Lookup.request_gap_fill(limit: 5)
    assert_equal requested, bare.reload.enrich_requested_at, "a waiting request isn't renewed"
  end

  test "only a published category counts, and the 90 days run from the read, not the request" do
    unpublished = company("Draft Category Fission", role: false, website: "https://draft.example")
    OrganizationRole.create!(organization: unpublished, role: @role)
    recent = company("Recent Fission", website: "https://recent.example", enrich_requested_at: 100.days.ago, enriched_at: 80.days.ago)
    old = company("Old Fission", website: "https://old.example", enrich_requested_at: 100.days.ago, enriched_at: 95.days.ago)

    Directory::Lookup.request_gap_fill(limit: 10)
    assert_nil unpublished.reload.enriched_at
    assert_equal 100.days.ago.to_date, recent.reload.enrich_requested_at.to_date, "read 80 days ago: not yet"
    assert_equal Date.current, old.reload.enrich_requested_at.to_date
    refute unpublished.reload.enrich_requested_at&.today?
  end

  test "a published company with an SEC CIK and no HQ is asked for first, even without a category or website" do
    listed = company("Listed Fission", role: false, sec_cik: "0001018724")
    bare = company("Bare Fission", website: "https://bare.example")
    with_hq = company("Listed With HQ", role: false, sec_cik: "0000000002", hq_city: "Seattle", hq_state: "WA")

    Directory::Lookup.request_gap_fill(limit: 1)
    assert listed.reload.enrich_requested_at, "EDGAR states its address"
    assert_nil bare.reload.enrich_requested_at
    assert_nil with_hq.reload.enrich_requested_at
  end
end
