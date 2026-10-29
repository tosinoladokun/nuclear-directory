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
end
