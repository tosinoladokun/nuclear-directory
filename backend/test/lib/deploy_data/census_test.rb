require "test_helper"

class DeployData::CensusTest < ActiveSupport::TestCase
  # Data Quality's published counts (docs/DATA.md): pending crawler records
  # and their quotes don't count; a docketed unit with no site does.
  test "public totals count only what the public sees" do
    before = DeployData::Census.public_totals
    assert_equal Directory::Lookup.published_counts.values.sum, before["facts"]

    source = Source.create!(url: "https://example.com/census-test", domain: "example.com", source_kind: "web_page")
    pending = Organization.create!(name: "Pending Census Co", slug: "pending-census-co", verification_status: "pending")
    Evidence.create!(subject: pending, source:, quote: "Pending Census Co exists.", found_by: "crawler")
    Facility.create!(name: "Siteless Census 1", slug: "siteless-census-1", nrc_docket: "05099999", status: "operating", verification_status: "pending")
      .update_columns(verification_status: "verified")
    # Decommissioning units (#312) and units with no status aren't reactors.
    Facility.create!(name: "Retired Census 1", slug: "retired-census-1", nrc_docket: "05099998", status: "decommissioning", verification_status: "pending")
      .update_columns(verification_status: "verified")
    Facility.create!(name: "Unknown Census 1", slug: "unknown-census-1", nrc_docket: "05099997", verification_status: "pending")
      .update_columns(verification_status: "verified")

    after = DeployData::Census.public_totals
    assert_equal before["quotes"], after["quotes"], "a pending record's quote isn't counted"
    assert_equal before["sources"], after["sources"]
    assert_equal before["companies"], after["companies"]
    assert_equal before["reactors"] + 1, after["reactors"], "only the operating one counts; a site-less one does"
  end
end
