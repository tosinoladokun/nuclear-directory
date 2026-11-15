require "test_helper"
require_relative "support/dummy_plugin"

# #244: confirming a link finds its company the way match does (brand, website), and a unit's claim finds the
# decided link on its site.
class DataQuality::LinkResolutionTest < ActiveSupport::TestCase
  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/link-resolution.html", source_kind: "dummy", crawl_status: "ok")
    @client = DataQuality::DirectoryClient.new
  end

  def ends(organization) = @client.send(:link_end_ids, { "organization" => organization })[:organization_id]

  test "a link's company is found by brand or website as match finds it; an ambiguous one finds nothing" do
    constellation = Directory::FactWriter.write(:organization, { name: "Constellation Energy Corporation", website: "https://www.constellationenergy.com" }).id
    terrapower = Directory::FactWriter.write(:organization, { name: "TerraPower Test", website: "https://www.terrapower-test.com" }).id
    assert_equal constellation, ends("name" => "Constellation Energy Generation, LLC"), "a legal-entity variant of exactly one company"
    assert_equal terrapower, ends("name" => "Somebody Else", "website" => "https://www.terrapower-test.com"), "by website"
    assert_nil ends("name" => "Constellation Energy Corporation", "website" => "https://www.terrapower-test.com"), "name and website disagree"
    assert_nil ends("name" => "Constellation Energy Generation, LLC", "website" => "https://www.terrapower-test.com"), "brand and website disagree"
  end

  test "a unit's claim is matched to the decided link on its site, not proposed as a new unit-level link" do
    site = Facility.create!(name: "Zephyr Point", facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    Facility.create!(name: "Zephyr Point 1", facility_type: "power_reactor", parent: site, nrc_docket: "05099001", verification_status: "verified", verified_by: "human:tosin")
    company = Organization.find(Directory::FactWriter.write(:organization, { name: "Zephyr Nuclear Co" }).id)
    link = FacilityRelationship.create!(organization: company, facility: site, relationship_type: "operates")
    link.verify!(by: "human:tosin")
    claim = Candidate.create!(source: @source, kind: "facility_relationship", quote: "Zephyr Point 1 | Zephyr Nuclear Co", payload: {
      "organization" => { "name" => "Zephyr Nuclear Co" }, "facility" => { "name" => "Zephyr Point 1", "nrc_docket" => "05099001" },
      "relationship_type" => "operates" })

    assert_no_difference -> { FacilityRelationship.count } do
      DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    end
    assert_equal [ "matched", link.id ], [ claim.reload.status, claim.subject_id ], claim.notes
  end

  test "a unit's ownership share is never matched to its site's owns link" do
    site = Facility.create!(name: "Zephyr Point", facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    Facility.create!(name: "Zephyr Point 1", facility_type: "power_reactor", parent: site, nrc_docket: "05099001", verification_status: "verified", verified_by: "human:tosin")
    company = Organization.find(Directory::FactWriter.write(:organization, { name: "Zephyr Nuclear Co" }).id)
    link = FacilityRelationship.create!(organization: company, facility: site, relationship_type: "owns", ownership_pct: 50)
    link.verify!(by: "human:tosin")
    claim = Candidate.create!(source: @source, kind: "facility_relationship", quote: "Zephyr Point 1 | Zephyr Nuclear Co | 30%", payload: {
      "organization" => { "name" => "Zephyr Nuclear Co" }, "facility" => { "name" => "Zephyr Point 1", "nrc_docket" => "05099001" },
      "relationship_type" => "owns", "ownership_pct" => 30 })

    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_not_equal link.id, claim.reload.subject_id, "the unit's 30% is its own link, not the site's 50%"
    assert_equal 50, link.reload.ownership_pct
  end
end
