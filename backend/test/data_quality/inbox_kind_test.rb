require "test_helper"
require_relative "support/dummy_plugin"

# Tosin's inbox (#548): only what's new or changes his decisions; Data Quality
# settles matching first, and a restatement confirms itself.
class DataQuality::InboxKindTest < ActiveSupport::TestCase
  setup do
    @company = Organization.create!(name: "Kind Fission", hq_city: "Austin", verification_status: "verified", verified_by: "human:tosin")
    @company.aliases.create!(alias: "Kind Fission")
    @page = Source.create!(url: "https://www.nrc.gov/test/kinds.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: "Kind Fission is in Austin. KIND FISSION INC. Kind Fission is in Dallas.")
    # An earlier, decided batch, so this one isn't the source's first.
    first = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
    Candidate.create!(source: @page, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
  end

  def claim(payload, **options) = Candidate.create!(source: @page, crawl_run: @run, kind: "organization", payload:, quote: "q", **options)
  def kind(candidate) = DataQuality::Review.inbox_kind(candidate.reload)

  test "new records and facts, changes, and Data Quality's own" do
    pending = Organization.create!(name: "Brand New Fission", verification_status: "pending")
    assert_equal "new_record", kind(claim({ "name" => "Brand New Fission" }, status: "matched", subject_type: "Organization", subject_id: pending.id, proposed_subject: true))
    role = OrganizationRole.create!(organization: @company, role: Role.first || Role.create!(key: "fuel", name: "Fuel"), verification_status: "pending")
    link = Candidate.create!(source: @page, crawl_run: @run, kind: "organization_role", quote: "q", status: "matched", subject_type: "OrganizationRole",
      subject_id: role.id, proposed_subject: true, payload: { "organization" => { "name" => "Kind Fission" }, "role" => role.role.key })
    assert_equal "new_fact", kind(link)
    assert_equal "change", kind(claim({ "name" => "Kind Fission", "hq_city" => "Dallas" }, status: "matched", subject_type: "Organization", subject_id: @company.id))
    assert_equal "dq", kind(claim({ "name" => "Unsettled Co" }, status: "needs_review", notes: %(no exact match for "Unsettled Co")))
  end

  test "a restatement confirms itself at match, with its source as evidence" do
    same = claim({ "name" => "KIND FISSION INC.", "hq_city" => "Austin" }, status: "new")
    stats = DataQuality::Stages::Match.call(plugin: DummyPlugin.new).stats
    assert_equal 1, stats["evidence_only"], "counted in the run's stats"
    assert_equal [ "confirmed", @company.id ], same.reload.values_at(:status, :subject_id), same.notes
    assert Evidence.exists?(subject: @company, source: @page)
  end
end
