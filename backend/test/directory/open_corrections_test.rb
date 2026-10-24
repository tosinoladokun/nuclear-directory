require "test_helper"

# Directory::Lookup.open_corrections? (safe classes' G4): an unresolved
# correction report on any address that shows the fact.
class Directory::OpenCorrectionsTest < ActiveSupport::TestCase
  def report(path) = CorrectionReport.create!(subject: "A plant", page_path: path, message: "Its status is wrong.")

  test "a report filed at a reactor's own page still counts once it's grouped under a site" do
    unit = Facility.create!(name: "Imaginary Point 1", nrc_docket: "05099901", facility_type: "power_reactor")
    report("/plants/#{unit.slug}")
    site = Facility.create!(name: "Imaginary Point")
    unit.update!(parent: site)

    assert Directory::Lookup.open_corrections?(type: "Facility", id: unit.id)
    refute Directory::Lookup.open_corrections?(type: "Facility", id: site.id), "the site's own page has no report"
  end

  test "a unit's site's page counts, and a closed report doesn't" do
    site = Facility.create!(name: "Imaginary Point")
    unit = Facility.create!(name: "Imaginary Point 2", nrc_docket: "05099902", facility_type: "power_reactor", parent: site)
    filed = report("/plants/#{site.slug}#unit-#{unit.slug}")

    assert Directory::Lookup.open_corrections?(type: "Facility", id: unit.id)
    filed.update!(status: "closed", resolution: "fixed", decided_by: "human:tosin", decided_at: Time.current)
    refute Directory::Lookup.open_corrections?(type: "Facility", id: unit.id)
  end

  test "a report filed at a page's address with a trailing slash counts, for a plant and a company" do
    site = Facility.create!(name: "Imaginary Point")
    company = Organization.create!(name: "Imaginary Fission")
    report("/plants/#{site.slug}/")
    report("/companies/#{company.slug}/?ref=x")

    assert Directory::Lookup.open_corrections?(type: "Facility", id: site.id)
    assert Directory::Lookup.open_corrections?(type: "Organization", id: company.id)
  end

  test "a deal term counts a report on the pages of the link or company it's under" do
    company = Organization.create!(name: "Imaginary Fission")
    buyer = Organization.create!(name: "Imaginary Cloud")
    round = DealTerm.create!(link: company, term_type: "funding_round", external_id: "0009999999-26-000001", amount_usd: 5_000_000)
    link = Relationship.create!(from_organization: buyer, to_organization: company, relationship_type: "offtake_with")
    offtake = DealTerm.create!(link:, term_type: "offtake", capacity_mw: 100)

    refute Directory::Lookup.open_corrections?(type: "DealTerm", id: round.id)
    report("/companies/#{company.slug}")
    assert Directory::Lookup.open_corrections?(type: "DealTerm", id: round.id)
    assert Directory::Lookup.open_corrections?(type: "DealTerm", id: offtake.id)
  end
end
