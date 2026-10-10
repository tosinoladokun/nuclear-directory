require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  COUNTED = %w[Organization OrganizationAlias OrganizationRole OrganizationTechnology Facility Relationship
    FacilityRelationship Source Evidence Role Technology].map { |model| "#{model}.count" }

  def load_seeds
    silence_warnings { load Rails.root.join("db/seeds.rb") }
  end

  test "seeds roles and technologies" do
    load_seeds

    assert Role.find_by!(key: "reactor_vendor").description.present?
    assert_equal Role.find_by!(key: "coolant"), Role.find_by!(key: "molten_salt").parent
    assert_equal Role.find_by!(key: "fuel"), Role.find_by!(key: "enrichment").parent
    assert_equal Technology.find_by!(key: "fission"), Technology.find_by!(key: "smr").parent
    assert_nil Technology.find_by!(key: "fusion").parent
  end

  test "loads the hand-checked organizations as verified facts with evidence" do
    load_seeds

    assert_equal 45, Organization.verified.count
    assert_equal 60, OrganizationRole.verified.count
    assert_equal 27, OrganizationTechnology.verified.count
    assert_equal 53, Relationship.verified.count
    assert_equal 28, Facility.verified.count
    assert_equal 45, FacilityRelationship.verified.count
    assert_equal [ "human:tosin" ], Relationship.distinct.pluck(:verified_by)
    assert_equal [ 1 ], OrganizationRole.distinct.pluck(:confidence)

    georgia_power = Directory::Lookup.organization(name: "Georgia Power Company")
    southern = Directory::Lookup.organization(name: "Southern Company")
    link = Relationship.find_by!(from_organization_id: georgia_power.id, to_organization_id: southern.id)
    assert link.subsidiary_of?
    assert_equal "human", link.evidence.sole.found_by
    assert_match "Georgia Power", link.evidence.sole.quote
  end

  test "loads the fuel chain from the gap research" do
    load_seeds

    mill = Facility.find_by!(name: "White Mesa Mill")
    assert mill.mill?
    assert mill.operating?, "a later mention without status doesn't blank it"
    assert_equal "UT", mill.state

    converdyn = Directory::Lookup.organization(name: "ConverDyn")
    solstice = Directory::Lookup.organization(name: "Solstice Advanced Materials")
    assert Relationship.exists?(from_organization_id: converdyn.id, to_organization_id: solstice.id,
      relationship_type: "subsidiary_of")
    assert_includes Organization.find(converdyn.id).roles.pluck(:key), "conversion"
  end

  test "Plant Vogtle is one site-level record covering every unit" do
    load_seeds

    vogtle = Facility.find_by!(name: "Plant Vogtle")
    assert_nil Facility.find_by(name: "Plant Vogtle Units 3 & 4")
    links = vogtle.facility_relationships.includes(:organization).to_h { |link| [ link.organization.slug, link ] }
    assert links["georgia-power"].owns?
    assert links["westinghouse-electric-company"].vendor_for?
    assert_match "Units 3 and 4", links["westinghouse-electric-company"].description
  end

  test "CFS and Dominion share one ARC facility" do
    load_seeds

    arc = Facility.find_by!(name: "ARC fusion power plant (Chesterfield County, VA)")
    links = arc.facility_relationships.includes(:organization).to_h { |link| [ link.organization.slug, link ] }
    assert_equal %w[commonwealth-fusion-systems dominion-energy google], links.keys.sort
    assert links["google"].offtakes_from?
    assert_match "leasing rights", links["dominion-energy"].description
    assert_equal "Dominion Energy Virginia currently owns the proposed site.", links["dominion-energy"].evidence.sole.quote
  end

  test "is safe to re-run" do
    load_seeds
    Role.find_by!(key: "fuel").update!(name: "Edited")

    assert_no_difference(COUNTED) { load_seeds }
    assert_equal "Fuel", Role.find_by!(key: "fuel").name
  end
end
