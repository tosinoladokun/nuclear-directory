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
    pending = give_sourced_role(Organization.create!(name: "Brand New Fission", verification_status: "pending"))
    assert_equal "new_record", kind(claim({ "name" => "Brand New Fission" }, status: "matched", subject_type: "Organization", subject_id: pending.id, proposed_subject: true))
    role = OrganizationRole.create!(organization: @company, role: Role.first || Role.create!(key: "fuel", name: "Fuel"), verification_status: "pending")
    link = Candidate.create!(source: @page, crawl_run: @run, kind: "organization_role", quote: "q", status: "matched", subject_type: "OrganizationRole",
      subject_id: role.id, proposed_subject: true, payload: { "organization" => { "name" => "Kind Fission" }, "role" => role.role.key })
    assert_equal "new_fact", kind(link)
    assert_equal "change", kind(claim({ "name" => "Kind Fission", "hq_city" => "Dallas" }, status: "matched", subject_type: "Organization", subject_id: @company.id))
    assert_equal "dq", kind(claim({ "name" => "KIND FISSION INC.", "hq_city" => "Austin" }, status: "matched", subject_type: "Organization", subject_id: @company.id)),
      "a restatement that slipped past match isn't a change"
    assert_equal "dq", kind(claim({ "name" => "Unsettled Co" }, status: "needs_review", notes: %(no exact match for "Unsettled Co")))
  end

  test "a restatement confirms itself at match, with its source as evidence" do
    same = claim({ "name" => "KIND FISSION INC.", "hq_city" => "Austin" }, status: "new")
    same.update!(quote: "KIND FISSION INC.")
    absent = claim({ "name" => "KIND FISSION INC.", "hq_city" => "Austin" }, status: "new")
    absent.update!(quote: "Kind Fission moved to Mars.")
    stats = DataQuality::Stages::Match.call(plugin: DummyPlugin.new).stats
    assert_equal 2, stats["evidence_only"], "counted in the run's stats (the second rests on the first's quote)"
    assert_equal [ "confirmed", @company.id ], same.reload.values_at(:status, :subject_id), same.notes
    assert Evidence.exists?(subject: @company, source: @page)
    assert_not Evidence.exists?(subject: @company, quote: "Kind Fission moved to Mars."), "a quote the source lacks is never cited"
  end

  test "a claim on a pending record is part of its first publication; news is a new fact; a first batch is Data Quality's" do
    pending = give_sourced_role(Organization.create!(name: "Second Copy Fission", verification_status: "pending"))
    copy = claim({ "name" => "Second Copy Fission" }, status: "matched", subject_type: "Organization", subject_id: pending.id)
    assert_equal "new_record", kind(copy), "another page's copy of a proposal"
    news = Candidate.create!(source: @page, crawl_run: @run, kind: "news_item", quote: "q", status: "matched", subject_type: "Organization",
      subject_id: @company.id, payload: { "title" => "Kind Fission expands", "organization" => { "name" => "Kind Fission" } })
    assert_equal "new_fact", kind(news)
    first_run = CrawlRun.create!(source_kind: "first_kind", stage: "crawl", status: "succeeded", started_at: 1.hour.ago)
    fresh = Source.create!(url: "https://www.nrc.gov/test/first.html", source_kind: "first_kind", crawl_status: "ok", content_sha256: "f")
    first = Candidate.create!(source: fresh, crawl_run: first_run, kind: "organization", payload: { "name" => "Brand New Two" }, quote: "q",
      status: "matched", subject_type: "Organization", subject_id: Organization.create!(name: "Brand New Two", verification_status: "pending").id,
      proposed_subject: true)
    assert_equal "dq", kind(first)
  end

  test "a restatement already waiting from before confirms itself on the next run" do
    waiting = claim({ "name" => "KIND FISSION INC.", "hq_city" => "Austin" }, status: "matched", subject_type: "Organization", subject_id: @company.id)
    waiting.update!(quote: "KIND FISSION INC.")
    change = claim({ "name" => "Kind Fission", "hq_city" => "Dallas" }, status: "matched", subject_type: "Organization", subject_id: @company.id)
    change.update!(quote: "Kind Fission is in Dallas.")
    stats = DataQuality::Stages::Match.call(plugin: DummyPlugin.new).stats
    assert waiting.reload.status_confirmed?, waiting.notes
    assert change.reload.status_matched?, "a real change still waits"
    assert_equal 1, stats["evidence_only"]
    assert_equal [ 1, 0, 1 ], stats.values_at("candidates", "matched", "confirmed"), "the run's totals add up"
    assert Evidence.exists?(subject: @company, quote: "KIND FISSION INC.")
  end

  test "only a new name for a published company is Data Quality's, not a Change" do
    variant = claim({ "name" => "Kind Fission Holdings" }, status: "matched", subject_type: "Organization", subject_id: @company.id)
    assert_equal "dq", kind(variant)
  end

  test "a new company without a sourced category stays Data Quality's" do
    bare = Organization.create!(name: "No Role Co", verification_status: "pending")
    c = claim({ "name" => "No Role Co" }, status: "matched", subject_type: "Organization", subject_id: bare.id, proposed_subject: true)
    assert_equal "dq", kind(c)
    give_sourced_role(bare)
    assert_equal "new_record", kind(c)
  end
end
