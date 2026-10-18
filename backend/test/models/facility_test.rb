require "test_helper"

class FacilityTest < ActiveSupport::TestCase
  setup { @site = facilities(:vogtle) }

  test "each status scope is exactly that status: not_operating isn't 'everything but operating'" do
    idle = Facility.create!(name: "Idle Plant", status: "not_operating")
    planned = Facility.create!(name: "Planned Plant", status: "planned")
    running = Facility.create!(name: "Running Plant", status: "operating")

    assert_includes Facility.not_operating, idle
    assert_not_includes Facility.not_operating, planned
    assert_not_includes Facility.not_operating, running
    assert_equal [ running.id ], Facility.operating.where(id: [ idle.id, planned.id, running.id ]).ids
    assert idle.not_operating?
    assert_not Facility.respond_to?(:not_planned), "no generated opposites"
  end

  test "a unit belongs to its site" do
    unit = Facility.create!(name: "Vogtle Unit 3", parent: @site, facility_type: "power_reactor", status: "operating")
    assert_equal "vogtle-unit-3", unit.slug
    assert_includes @site.children, unit
  end

  test "only sites and their units: no unit under a unit, and a site with units can't become one" do
    unit = Facility.create!(name: "Vogtle Unit 3", parent: @site)

    grandchild = Facility.new(name: "Vogtle Unit 3 annex", parent: unit)
    assert_not grandchild.valid?
    assert_includes grandchild.errors[:parent], "must be a site, not a unit"

    other = Facility.create!(name: "Other Site")
    @site.parent = other
    assert_not @site.valid?
    assert_includes @site.errors[:parent], "can't be set: this site has units of its own"
  end

  test "a three-level chain built in memory is refused before anything is saved" do
    top = Facility.new(name: "Top Site")
    middle = Facility.new(name: "Middle", parent: top)
    bottom = Facility.new(name: "Bottom", parent: middle)

    assert_not bottom.valid?
    assert_includes bottom.errors[:parent], "must be a site, not a unit"
    assert_raises(ActiveRecord::RecordInvalid) { bottom.save! }
    assert_not Facility.exists?(name: "Top Site")
  end

  test "a generated slug that's taken gets a number" do
    first = Facility.create!(name: "Palisades", nrc_docket: "05000255")
    second = Facility.create!(name: "Palisades")
    third = Facility.create!(name: "Palisades")

    assert_equal %w[palisades palisades-2 palisades-3], [ first, second, third ].map(&:slug)
  end

  test "nrc docket is unique when present" do
    Facility.create!(name: "Unit A", facility_type: "power_reactor", status: "operating", nrc_docket: "05000424")
    dup = Facility.new(name: "Unit B", facility_type: "power_reactor", status: "operating", nrc_docket: "05000424")
    assert_not dup.valid?

    Facility.create!(name: "No docket 1", facility_type: "other", status: "planned", nrc_docket: " ")
    assert Facility.create!(name: "No docket 2", facility_type: "other", status: "planned").persisted?
  end

  test "fuel chain facility types" do
    %w[uranium_mine mill].each do |type|
      assert Facility.create!(name: "A #{type}", facility_type: type).persisted?
    end
  end

  test "type and status must be known values" do
    assert_not Facility.new(name: "X", facility_type: "spaceship", status: "operating").valid?
    assert_not Facility.new(name: "X", facility_type: "other", status: "vibing").valid?
  end

  test "an organization can own a share of a facility" do
    org = organizations(:westinghouse)
    link = FacilityRelationship.create!(organization: org, facility: @site, relationship_type: "owns", ownership_pct: 45.7)
    assert_includes org.facilities, @site
    assert_not FacilityRelationship.new(organization: org, facility: @site, relationship_type: "owns").valid?
    assert link.pending?
  end

  test "ownership_pct only applies to owns" do
    link = FacilityRelationship.new(organization: organizations(:westinghouse), facility: @site,
      relationship_type: "operates", ownership_pct: 10)
    assert_not link.valid?
  end

  # #117: a decided record carries when the decision was made so review
  # notes always show a date. The helpers set it explicitly; direct
  # constructors get it auto-filled.
  test "a non-pending record created directly gets verified_at auto-filled" do
    before = Time.current
    plant = Facility.create!(name: "Decided Direct", verification_status: "verified", verified_by: "human:test")
    assert_not_nil plant.verified_at
    assert_operator plant.verified_at, :>=, before
  end

  test "a non-pending record without verified_by is a validation error" do
    plant = Facility.new(name: "No Who", verification_status: "verified")
    plant.verified_at = Time.current  # bypasses the auto-fill
    assert_not plant.valid?
    assert_includes plant.errors[:verified_by], "is required for non-pending records (#117)"
  end

  test "pending records don't need a decision timestamp" do
    plant = Facility.create!(name: "Pending Direct")
    assert plant.pending?
    assert_nil plant.verified_at
    assert_nil plant.verified_by
  end

  test "an older decided record without a date still saves ordinary edits, and isn't stamped with today (#348)" do
    plant = Facility.create!(name: "Undated Decision", verification_status: "verified", verified_by: "human:tosin")
    plant.update_columns(verified_at: nil) # as a record decided before #117 could be

    plant.update!(city: "Waynesboro")
    assert_nil plant.reload.verified_at, "no invented decision date"

    taken_off = Facility.create!(name: "Undated Removal", verification_status: "verified", verified_by: "human:tosin")
    taken_off.unpublish!(by: "human:tosin", reason: "Test")
    taken_off.update_columns(verified_at: nil)
    result = Directory::FactWriter.write(:facility, { id: taken_off.id, city: "Somewhere" }, verification: { status: "unpublished", by: "human:tosin" })
    assert result.ok?, result.errors.to_sentence
  end

  test "a new decision still needs and gets a date" do
    plant = Facility.create!(name: "Pending First")
    plant.decided_by = "human:tosin" # as verify! and FactWriter say who decides
    plant.update!(verification_status: "verified", verified_by: "human:tosin")
    assert_not_nil plant.reload.verified_at
  end
end
