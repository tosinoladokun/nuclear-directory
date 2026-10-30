require "test_helper"
require_relative "support/dummy_plugin"

# #650: a developer's pre-application docket (NRC ADAMS) is a licensing-stage
# claim: matched to its company, proposed as a pending stage, decided by Tosin.
class DataQuality::LicensingStageClaimTest < ActiveSupport::TestCase
  setup do
    @company = Organization.create!(name: "Last Energy", verification_status: "verified", verified_by: "human:tosin")
    @company.aliases.create!(alias: "Last Energy")
    @source = Source.create!(url: "https://adamswebsearch2.nrc.gov/x", source_kind: "dummy", crawl_status: "ok", content_sha256: "s",
      content_text: "Pre-application meeting with Last Energy, Docket 99902104.")
  end

  def claim(payload) = Candidate.create!(source: @source, kind: "licensing_stage", status: "new", quote: "Pre-application meeting with Last Energy, Docket 99902104.",
    payload: { "organization" => { "name" => "Last Energy" }, "stage" => "pre_application", "nrc_docket" => "99902104", "effective_on" => "2026-09-14" }.merge(payload))

  test "matched to its company and proposed as a pending stage on the docket, worded plainly; it shows as a pending fact" do
    c = claim({})
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    c.reload
    assert_equal [ "matched", "LicensingStage", true ], c.values_at(:status, :subject_type, :proposed_subject), c.notes
    stage = LicensingStage.find(c.subject_id)
    assert_equal [ @company.id, "pre_application", "99902104", "pending" ], stage.values_at(:organization_id, :stage, :nrc_docket, :verification_status)
    assert_equal "Last Energy is at the NRC's pre-application stage (docket 99902104) since 14 Sep 2026.", DataQuality::Claim.describe(c)
    assert_equal "new_fact", DataQuality::Review.inbox_kind(c)
    assert_match "pre-application on NRC docket 99902104", Directory::Lookup.fact_state(type: "LicensingStage", id: stage.id).name
  end

  test "an unknown company waits for Data Quality" do
    c = claim({ "organization" => { "name" => "Nobody Reactors" } })
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_equal "needs_review", c.reload.status
  end

  test "a changed date on a human-verified stage is a difference; an expiry is worded; both owner kinds list as pending facts" do
    stage = LicensingStage.create!(organization: @company, stage: "pre_application", nrc_docket: "99902104", effective_on: Date.new(2026, 9, 14),
      verification_status: "verified", verified_by: "human:tosin")
    c = claim({ "effective_on" => "2026-10-01", "expires_on" => "2027-10-01" })
    c.update!(status: "matched", subject_type: "LicensingStage", subject_id: stage.id)
    record = DataQuality::DirectoryClient.new.fact(type: "LicensingStage", id: stage.id)
    assert_includes DataQuality::Differences.changes(c, record, directory: DataQuality::DirectoryClient.new).to_h.keys, "effective_on"
    assert_match "until 1 Oct 2027", DataQuality::Claim.describe(c)

    site = Facility.create!(name: "Stage Site", verification_status: "verified", verified_by: "human:tosin")
    LicensingStage.create!(facility: site, stage: "construction_permit", nrc_docket: "05000999", effective_on: Date.current, verification_status: "pending")
    LicensingStage.create!(organization: @company, stage: "withdrawn", nrc_docket: "99902105", effective_on: Date.current, verification_status: "pending")
    names = DataQuality::Review.pending_facts(kind: "licensing_stage").map { |fact| fact.attributes.to_h.values_at(:organization_name, :facility_name) }
    assert_includes names, [ nil, "Stage Site" ]
    assert_includes names, [ "Last Energy", nil ]
  end

  test "a corrected date on an existing stage matches that stage (by docket and stage) instead of making another" do
    stage = LicensingStage.create!(organization: @company, stage: "pre_application", nrc_docket: "99902104", effective_on: Date.new(2026, 9, 14),
      verification_status: "verified", verified_by: "human:tosin")
    c = claim({ "effective_on" => "2026-10-01" })
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_equal [ "LicensingStage", stage.id ], c.reload.values_at(:subject_type, :subject_id), c.notes
    assert_equal 1, LicensingStage.count
    assert_equal Date.new(2026, 9, 14), stage.reload.effective_on, "nothing overwritten at match"
  end
end
