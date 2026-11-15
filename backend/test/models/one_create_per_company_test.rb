require "test_helper"

# Data Quality, 11 Nov: a pending company is one Create. Its other company claims (a website or description from
# its own page) go with that row when checked, never as a Create of their own.
class OneCreatePerCompanyTest < ActiveSupport::TestCase
  setup do
    @page = Source.create!(url: "https://www.nrc.gov/test/one.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha", content_text: "q")
    first = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
    Candidate.create!(source: @page, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected")
    @run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    @company = give_sourced_role(Organization.create!(name: "Leapfrog Nuclear Co", verification_status: "pending"))
    @site = Source.create!(url: "https://leapfrog.example", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha", content_text: "Leapfrog builds reactors.")
  end

  def claim(source:, payload:, quote: "q", **extra)
    Candidate.create!(source:, crawl_run: @run, kind: "organization", status: "matched", quote:, payload: { "name" => "Leapfrog Nuclear Co", **payload },
      subject_type: "Organization", subject_id: @company.id, ai_source_sha256: "sha", **extra)
  end

  def creates = OwnerInbox.new.sections["new_record"].select { |entry| Candidate.find(entry.item.candidate_id).subject_id == @company.id }

  test "the company's checked website claim goes with its one Create; an unchecked one waits" do
    create = claim(source: @page, payload: {}, proposed_subject: true, ai_recommendation: "recommend_publish")
    website = claim(source: @site, payload: { "website" => "https://leapfrog.example" }, quote: "Leapfrog builds reactors.")
    DataQuality::Recommendations.record("#{website.id} approve: its own site", by: "human:dq")
    unchecked = claim(source: @site, payload: { "description" => "Builds reactors." }, quote: "Leapfrog builds reactors.")

    entry = creates.sole
    assert_equal create.id, entry.item.candidate_id
    assert_includes entry.ids, website.id
    assert_not_includes entry.ids, unchecked.id
  end

  test "an approval made before the claim was edited no longer rides along" do
    claim(source: @page, payload: {}, proposed_subject: true, ai_recommendation: "recommend_publish")
    website = claim(source: @site, payload: { "website" => "https://leapfrog.example" }, quote: "Leapfrog builds reactors.")
    DataQuality::Recommendations.record("#{website.id} approve: its own site", by: "human:dq")
    website.update!(payload: website.payload.merge("website" => "https://elsewhere.example"))
    assert_not_includes creates.sole.ids, website.id
  end

  test "after his No, what's left on the company stays with Data Quality, not as another Create" do
    create = claim(source: @page, payload: {}, proposed_subject: true, ai_recommendation: "recommend_publish")
    claim(source: @site, payload: { "description" => "Builds reactors." }, quote: "Leapfrog builds reactors.", status: "needs_review")
    DataQuality::Review.reject(creates.sole.ids, by: "human:tosin", reason: "Said no in Today")
    assert create.reload.status_rejected?
    assert_empty creates
  end

  test "a claim Data Quality said no to never rides along, even when the verifier recommended it (DQ, 12 Nov)" do
    claim(source: @page, payload: {}, proposed_subject: true, ai_recommendation: "recommend_publish")
    website = claim(source: @site, payload: { "website" => "https://leapfrog.example" }, quote: "Leapfrog builds reactors.", ai_recommendation: "recommend_publish")
    DataQuality::Recommendations.record("#{website.id} reject: not the company's site", by: "human:dq")
    assert_not_includes creates.sole.ids, website.id
  end
end
