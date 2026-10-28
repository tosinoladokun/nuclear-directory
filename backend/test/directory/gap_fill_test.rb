require "test_helper"

class Directory::GapFillTest < ActiveSupport::TestCase
  setup do
    Organization.update_all(enrich_requested_at: Time.current, enriched_at: Time.current)
    @role = Role.create!(key: "gap_fill_test", name: "Gap fill test")
  end

  def company(name, role: true, **attributes)
    Organization.create!(name:, verification_status: "verified", verified_by: "human:tosin", **attributes).tap do |org|
      OrganizationRole.create!(organization: org, role: @role) if role
    end
  end

  test "asks Enrich for published, categorised companies missing HQ or description, most missing first; lists those without a website" do
    bare = company("Bare Fission", website: "https://bare.example")
    half = company("Half Fission", website: "https://half.example", description: "Builds reactors.")
    full = company("Full Fission", website: "https://full.example", description: "x", hq_city: "Austin", hq_state: "TX")
    uncategorised = company("Loose Fission", role: false, website: "https://loose.example")
    company("Siteless Fission")
    pending = Organization.create!(name: "Pending Fission", website: "https://pending.example")

    assert_includes Directory::Lookup.request_gap_fill(limit: 1), "Siteless Fission"
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
end
