require "test_helper"

class Directory::GapFillTest < ActiveSupport::TestCase
  def company(name, **attributes)
    Organization.create!(name:, verification_status: "verified", verified_by: "human:tosin", **attributes)
  end

  setup { Organization.update_all(enrich_requested_at: Time.current, enriched_at: Time.current) }

  test "asks Enrich for the published companies with the most gaps and a website; lists those without one" do
    bare = company("Bare Fission", website: "https://bare.example")
    some = company("Some Fission", website: "https://some.example", description: "Builds reactors.", hq_city: "Austin", hq_state: "TX")
    full = company("Full Fission", website: "https://full.example", description: "x", short_description: "y", hq_city: "A", hq_state: "TX")
    OrganizationRole.create!(organization: full, role: Role.create!(key: "gap_fill_test", name: "Gap fill test"))
    company("Siteless Fission")
    pending = Organization.create!(name: "Pending Fission", website: "https://pending.example")

    assert_includes Directory::Lookup.request_gap_fill(limit: 1), "Siteless Fission"
    assert bare.reload.enrich_requested_at, "most gaps first"
    assert_nil some.reload.enrich_requested_at
    assert_nil full.reload.enrich_requested_at
    assert_nil pending.reload.enrich_requested_at, "unpublished companies aren't filled"

    Directory::Lookup.request_gap_fill(limit: 5)
    assert some.reload.enrich_requested_at
    assert_nil full.reload.enrich_requested_at, "no gaps, nothing to read"
    requested = bare.reload.enrich_requested_at
    Directory::Lookup.request_gap_fill(limit: 5)
    assert_equal requested, bare.reload.enrich_requested_at, "a waiting request isn't renewed"
  end
end
