require "test_helper"
require_relative "support/dummy_plugin"

# #721: a research reactor's licensed thermal power (kW thermal) arrives as a field
# on a facility claim, from the NRC's page, and is compared as a number.
class DataQuality::ThermalPowerClaimTest < ActiveSupport::TestCase
  QUOTE = "Power Level (kW): 1,100".freeze

  setup do
    @reactor = Facility.create!(name: "Test University Reactor", nrc_docket: "05000182", facility_type: "research_reactor",
      verification_status: "verified", verified_by: "human:tosin")
    @source = Source.create!(url: "https://www.nrc.gov/reactors/non-power/test.html", source_kind: "dummy", crawl_status: "ok",
      content_sha256: "s", content_text: QUOTE)
  end

  def claim(kw) = Candidate.create!(source: @source, kind: "facility", status: "new", quote: QUOTE,
    payload: { "name" => "Test University Reactor", "nrc_docket" => "05000182", "thermal_power_kw" => kw })

  test "matched by docket, worded in kW thermal, written on approval with its evidence marked for the field" do
    c = claim("1100")
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_equal [ "Facility", @reactor.id ], c.reload.values_at(:subject_type, :subject_id), c.notes
    assert_match "thermal power", DataQuality::Claim.describe(c)
    assert_match "1100 kW thermal", DataQuality::Claim.describe(c)
    assert DataQuality::Review.approve([ c.id ], by: "human:tosin").sole.ok?
    assert_equal BigDecimal("1100"), @reactor.reload.thermal_power_kw
    assert_equal [ "thermal_power_kw" ], @reactor.evidence.find_by!(quote: QUOTE).fields
  end

  test "the same power written differently is no difference; a different one is, and goes to review" do
    @reactor.update!(thermal_power_kw: BigDecimal("1100"))
    record = DataQuality::DirectoryClient.new.fact(type: "Facility", id: @reactor.id)
    same, other = claim("1100.0"), claim("2000")
    [ same, other ].each { |c| c.update!(status: "matched", subject_type: "Facility", subject_id: @reactor.id) }
    assert_empty DataQuality::Differences.with_human_verified(same, record, directory: DataQuality::DirectoryClient.new)
    assert_equal({ "thermal_power_kw" => [ "1100", "2000" ] }, DataQuality::Differences.with_human_verified(other, record, directory: DataQuality::DirectoryClient.new))
  end
end
