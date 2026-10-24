require "test_helper"

# Directory::FactWriter.confirm: does a source still say what a fact records (#240)?
class Directory::ConfirmTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @source = sources(:press_release)
    @unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", capacity_mw: "1227.40",
      verification_status: "verified", verified_by: BY)
    @unit.aliases.create!(alias: "Hope Creek Generating Station")
    @evidence = Evidence.create!(subject: @unit, source: @source, quote: "Hope Creek 1", found_by: "crawler")
  end

  def confirm(attributes, kind: :facility, source_id: @source.id, **)
    Directory::FactWriter.confirm(kind, { id: @unit.id }.merge(attributes), source_id:, quote: "Hope Creek 1", rows_sha256: "rows-1", **)
  end

  test "the same values, compared as stored, confirm and stamp only the evidence" do
    at = Time.zone.parse("2026-10-14 03:02")
    result = nil
    assert_no_difference [ "VerificationEvent.count", -> { @unit.reload.updated_at } ] do
      result = confirm({ name: "Hope Creek Generating Station", nrc_docket: " 05000354 ", capacity_mw: "1227.4000000000001" }, at:)
    end

    assert result.confirmed?, result.inspect
    assert_equal [ at, "rows-1" ], [ @evidence.reload.last_confirmed_at, @evidence.confirmed_sha256 ]
  end

  test "a different value is a difference; a name isn't compared, as verify doesn't" do
    assert_equal({ "state" => [ "NJ", "DE" ] }, confirm({ state: "DE" }).differences)
    assert_equal({ "capacity_mw" => [ "1227.4", "1230" ] }, confirm({ capacity_mw: "1230" }).differences)
    assert_nil @evidence.reload.last_confirmed_at, "a difference stamps nothing"
    assert confirm({ name: "Hope Creek Unit One" }).confirmed?, "which unit it is was settled by its docket"
  end

  test "a value the fact doesn't have yet is a difference; one the source doesn't state isn't" do
    assert_equal :different, confirm({ city: "Hancocks Bridge" }).outcome
    assert confirm({ city: nil }).confirmed?
  end

  test "the same values with no evidence from this source aren't confirmed: approving would add the source" do
    assert_equal :unsourced, confirm({ state: "NJ" }, source_id: sources(:nrc).id).outcome
  end

  test "a row the source now words differently isn't stamped as re-checked: approving adds the current quote" do
    result = Directory::FactWriter.confirm(:facility, { id: @unit.id, state: "NJ" }, source_id: @source.id, quote: "Hope Creek 1 (reworded)")

    assert_equal :unsourced, result.outcome
    assert_nil @evidence.reload.last_confirmed_at
  end

  test "a link is the same claim only between its own company and plant; a unit stands for its site" do
    site = Facility.create!(name: "Monticello", verification_status: "verified", verified_by: BY)
    other_unit = Facility.create!(name: "Monticello 1", nrc_docket: "05000263", parent: site)
    company = Organization.create!(name: "Northern States Power", verification_status: "verified", verified_by: BY)
    link = FacilityRelationship.create!(organization: company, facility: site, relationship_type: "operates",
      verification_status: "verified", verified_by: BY)
    Evidence.create!(subject: link, source: @source, quote: "row", found_by: "crawler")
    confirm_link = ->(organization_id, facility_id) do
      Directory::FactWriter.confirm(:facility_relationship, { id: link.id, organization_id:, facility_id:, relationship_type: "operates" },
        source_id: @source.id, quote: "row")
    end

    assert confirm_link.call(company.id, other_unit.id).confirmed?, "Monticello 1 is the site's unit"
    assert_equal({ "facility" => [ "Monticello", "Hope Creek 1" ] }, confirm_link.call(company.id, @unit.id).differences)
    assert_equal({ "organization" => [ "Northern States Power", "not in the directory" ] }, confirm_link.call(nil, site.id).differences)
  end

  test "given a check of the source, even the claim's own quote is stamped only if the source still has it" do
    result = confirm({ state: "NJ" }, in_source: ->(_quote) { false })

    assert_equal :unsourced, result.outcome
    assert_nil @evidence.reload.last_confirmed_at
  end

  test "a company is known by any of its aliases" do
    company = Organization.create!(name: "PSEG Nuclear", verification_status: "verified", verified_by: BY)
    company.aliases.create!(alias: "PSEG Nuclear LLC")
    Evidence.create!(subject: company, source: @source, quote: "PSEG Nuclear LLC", found_by: "crawler")

    result = Directory::FactWriter.confirm(:organization, { id: company.id, name: "PSEG Nuclear, LLC" }, source_id: @source.id, quote: "PSEG Nuclear LLC")

    assert result.confirmed?, result.inspect
  end

  test "a missing fact or an unknown attribute isn't confirmed" do
    assert_equal :missing, Directory::FactWriter.confirm(:facility, { id: 0 }, source_id: @source.id, quote: "x").outcome
    assert_match "unknown attributes: favourite", confirm({ favourite: "blue" }).errors.join
  end

  test "reconfirm_source stamps only the facts and quotes the rows still support, from that source" do
    other_source = Evidence.create!(subject: @unit, source: sources(:nrc), quote: "Hope Creek 1", found_by: "crawler")
    old_quote = Evidence.create!(subject: @unit, source: @source, quote: "Hope Creek 1 (old wording)", found_by: "crawler")
    dropped = Facility.create!(name: "Salem 1", nrc_docket: "05000272")
    dropped_evidence = Evidence.create!(subject: dropped, source: @source, quote: "Hope Creek 1", found_by: "crawler")
    at = Time.zone.parse("2026-10-14 03:02")

    stamped = Directory::FactWriter.reconfirm_source(source_id: @source.id, facts: [ [ "Facility", @unit.id ] ],
      quotes: [ "Hope Creek 1" ], rows_sha256: "rows-2", at:)

    assert_equal 1, stamped
    assert_equal [ at, "rows-2" ], [ @evidence.reload.last_confirmed_at, @evidence.confirmed_sha256 ]
    assert_nil other_source.reload.last_confirmed_at
    assert_nil old_quote.reload.last_confirmed_at
    assert_nil dropped_evidence.reload.last_confirmed_at, "not a fact the rows still support"
    assert_equal 0, Directory::FactWriter.reconfirm_source(source_id: @source.id, facts: [], quotes: [ "x" ], rows_sha256: "r")
  end

  test "a new monthly file stating what an earlier one supports adds its evidence and confirms; another kind of source still waits" do
    august = Source.create!(url: "https://www.eia.gov/test/august_generator2026.xlsx", source_kind: "eia_generators", crawl_status: "ok")
    september = Source.create!(url: "https://www.eia.gov/test/september_generator2026.xlsx", source_kind: "eia_generators", crawl_status: "ok")
    Evidence.create!(subject: @unit, source: august, quote: "Hope Creek 1,1227.4", found_by: "crawler")

    result = Directory::FactWriter.confirm(:facility, { id: @unit.id, capacity_mw: "1227.4" }, source_id: september.id,
      quote: "Hope Creek 1,1227.4", source_kind: "eia_generators")
    assert result.confirmed?, result.inspect
    assert Evidence.exists?(subject: @unit, source: september, quote: "Hope Creek 1,1227.4")

    other = Source.create!(url: "https://example.com/other", source_kind: "web_page", crawl_status: "ok")
    result = Directory::FactWriter.confirm(:facility, { id: @unit.id, capacity_mw: "1227.4" }, source_id: other.id, quote: "x", source_kind: "web_page")
    assert_equal :unsourced, result.outcome, "a first source of its kind still waits for a person"
  end

  test "a value the source gives with fewer decimals agrees when ours rounds to it" do
    @unit.update_columns(latitude: 39.467528, capacity_mw: "1227.40")
    assert confirm({ latitude: "39.4675", capacity_mw: "1227" }).confirmed?
    assert_not confirm({ latitude: "39.4699" }).confirmed?
  end
end
