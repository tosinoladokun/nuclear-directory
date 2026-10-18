require "test_helper"

# Directory::FactWriter.merge_facility: one page per plant (#229).
class Directory::MergeFacilityTest < ActiveSupport::TestCase
  BY = "human:tosin"
  VERIFIED = { verification_status: "verified", verified_by: BY }.freeze

  setup do
    # As in production: the seed site has the units and owners, EIA's has the plant ID.
    @into = Facility.create!(name: "Plant Vogtle", state: "GA", facility_type: "power_reactor", **VERIFIED)
    @into.aliases.create!(alias: "Plant Vogtle Units 3 & 4")
    @unit = Facility.create!(name: "Vogtle 3", parent: @into, nrc_docket: "05200025", **VERIFIED)
    @from = Facility.create!(name: "Vogtle", eia_plant_id: "649", state: "GA", status: "operating",
      latitude: "33.1427", longitude: "-81.7625", **VERIFIED)
    @from_slug = @from.slug
    @company = Organization.create!(name: "Georgia Power", **VERIFIED)
  end

  # Every merge here also checks the admin's read-only preview (#325): it
  # refuses what the merge refuses, and says what moved exactly as the
  # merge's own audit reason does. (It doesn't take a `by:`: who merges is
  # checked when they confirm.)
  def merge(**options)
    return Directory::FactWriter.merge_facility(from_id: @from.id, into_id: @into.id, by: BY, **options) if options.key?(:by)

    preview, moved = Directory::FactWriter.merge_preview(type: "Facility", from_id: @from.id, into_id: @into.id)
    result = Directory::FactWriter.merge_facility(from_id: @from.id, into_id: @into.id, by: BY, **options)
    assert_equal result.ok?, preview.ok?, "preview and merge agree on whether it can be done: #{result.errors + preview.errors}"
    assert_equal VerificationEvent.where(subject: @from).order(:id).last.reason[/Moved: (.*)\z/, 1], moved if result.ok?
    result
  end

  test "the plant ID, blank fields, aliases, links, evidence and candidates move, and from is unpublished" do
    link = @from.facility_relationships.create!(organization: @company, relationship_type: "owns")
    evidence = Evidence.create!(subject: @from, source: sources(:press_release), quote: "Vogtle, Waynesboro", found_by: "crawler")
    candidate = Candidate.create!(source: sources(:press_release), kind: "facility", quote: "q", status: "matched",
      payload: { "name" => "Vogtle" }, subject_type: "Facility", subject_id: @from.id)

    assert merge.ok?

    @into.reload
    assert_equal [ "649", "operating", "33.1427" ], [ @into.eia_plant_id, @into.status, @into.latitude.to_s ]
    assert_equal "power_reactor", @into.facility_type
    assert_nil @from.reload.eia_plant_id
    assert_equal [ "plant vogtle units 3 and 4", "vogtle" ], @into.aliases.pluck(:normalized_alias).sort
    assert_equal [ @into.id ] * 3, [ link.reload.facility_id, evidence.reload.subject_id, candidate.reload.subject_id ]
    assert @from.unpublished?
    reason = @from.verification_events.order(:id).last.reason
    assert_match "Merged into Plant Vogtle (##{@into.id})", reason
    assert_match "eia_plant_id, status, latitude, longitude", reason
    assert_equal @into, Facility.find_by_former_slug(@from_slug)
    assert_equal @into.id, Directory::Lookup.facility(eia_plant_id: "649").id, "EIA's crawl finds the kept site"
  end

  test "into keeps its own values, its units, and a link it already has; a closed link stays behind" do
    @from.update!(state: "SC")
    other_unit = Facility.create!(name: "Vogtle 4", parent: @from, nrc_docket: "05200026", **VERIFIED)
    @into.facility_relationships.create!(organization: @company, relationship_type: "owns")
    duplicate = @from.facility_relationships.create!(organization: @company, relationship_type: "owns")
    eia_operator = @from.facility_relationships.create!(organization: Organization.create!(name: "TalenEnergy", **VERIFIED),
      relationship_type: "operates", **VERIFIED)
    eia_operator.unpublish!(by: BY, reason: "EIA's Entity Name isn't the operator (#227)")

    assert merge.ok?

    assert_equal "GA", @into.reload.state
    assert_equal [ @into.id ] * 2, [ @unit.reload.parent_id, other_unit.reload.parent_id ]
    assert duplicate.reload.rejected?
    assert_equal @from.id, duplicate.facility_id
    assert_equal [ @from.id, "unpublished" ], [ eia_operator.reload.facility_id, eia_operator.verification_status ]
  end

  test "into's own history says which values came from the merged site" do
    assert merge.ok?

    event = @into.verification_events.order(:id).last
    assert_equal "Vogtle (##{@from.id}) merged in: its eia_plant_id, status, latitude, longitude", event.reason
    assert_equal [ nil, "649" ], event.changed_values["eia_plant_id"]
    assert_equal BY, event.by
  end

  test "an alias that's another plant's name isn't added (#89); from's own name is" do
    Facility.create!(name: "Vogtle Electric Generating Plant")
    @from.aliases.create!(alias: "Vogtle Electric Generating Plant!")
    @from.aliases.create!(alias: "VEGP")

    assert merge.ok?

    assert_equal [ "plant vogtle units 3 and 4", "vegp", "vogtle" ], @into.aliases.pluck(:normalized_alias).sort
  end

  test "a docketed NRC unit not yet under a site isn't merged as a site" do
    unit = Facility.create!(name: "Columbia Generating Station", nrc_docket: "05000397", **VERIFIED)

    assert_match "is a unit", Directory::FactWriter.merge_facility(from_id: @from.id, into_id: unit.id, by: BY).errors.join
    assert_match "is a unit", Directory::FactWriter.merge_facility(from_id: unit.id, into_id: @into.id, by: BY).errors.join
    assert @from.reload.verified?
  end

  test "the history records the value into actually had, even an empty string" do
    @into.update_columns(city: "")
    @from.update!(city: "Waynesboro")

    assert merge.ok?

    assert_equal [ "", "Waynesboro" ], @into.verification_events.order(:id).last.changed_values["city"]
  end

  test "two sites with different EIA plant IDs are two plants, and aren't merged" do
    @into.update!(eia_plant_id: "2410")

    result = merge

    assert_match "two plants, not one", result.errors.join
    assert_equal [ "649", "verified" ], [ @from.reload.eia_plant_id, @from.verification_status ]
  end

  test "into's public snapshot expires even when nothing about it was filled" do
    @from.update_columns(eia_plant_id: nil, status: nil, latitude: nil, longitude: nil)
    before = @into.updated_at
    travel 1.minute

    assert merge.ok?

    assert_operator @into.reload.updated_at, :>, before
  end

  test "evidence into already has isn't copied" do
    Evidence.create!(subject: @into, source: sources(:press_release), quote: "Vogtle, Waynesboro", found_by: "crawler")
    Evidence.create!(subject: @from, source: sources(:press_release), quote: "Vogtle, Waynesboro", found_by: "crawler")

    assert merge.ok?

    assert_equal 1, Evidence.where(subject: @into).count
    assert_empty Evidence.where(subject: @from)
  end

  test "refused: not a human, the same plant, a unit, a closed plant, a missing one; nothing changes" do
    assert_match "human's decision", merge(by: "agent:x").errors.join
    assert_match "into itself", Directory::FactWriter.merge_facility(from_id: @into.id, into_id: @into.id, by: BY).errors.join
    assert_match "is a unit", Directory::FactWriter.merge_facility(from_id: @unit.id, into_id: @into.id, by: BY).errors.join
    assert_match "no plant with id 0", Directory::FactWriter.merge_facility(from_id: 0, into_id: @into.id, by: BY).errors.join
    @into.unpublish!(by: BY, reason: "test")
    assert_match "merge into a live plant", merge.errors.join

    assert_equal [ "649", "verified" ], [ @from.reload.eia_plant_id, @from.verification_status ]
  end
end
