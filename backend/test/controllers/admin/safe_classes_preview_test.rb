require "test_helper"

# The recommendations page with the verifier's safe classes (#306, option
# A): a second group, each item tagged with its class and what it changes,
# taken by the same Accept, under one fingerprint.
class Admin::SafeClassesPreviewTest < ActionDispatch::IntegrationTest
  SafeClasses = DataQuality::SafeClasses
  FUNDER = "U.S. Department of Energy"
  FIRST = "1 award from the U.S. Department of Energy totaling $1.0 million, 2021: DENE0000001."
  SECOND = "2 awards from the U.S. Department of Energy totaling $3.0 million (2021–2023): DENE0000001, DENE0000002."

  setup do
    text = "the award rows"
    @source = Source.create!(url: "https://api.usaspending.gov/test/recipient/2", source_kind: "usaspending_doe_awards", crawl_status: "ok",
      http_status: 200, fetched_at: Time.current, content_text: text, content_sha256: Digest::SHA256.hexdigest(text))
    Source.create!(url: "https://api.usaspending.gov/test/index", source_kind: "usaspending_api", crawl_status: "ok", http_status: 200,
      fetched_at: 1.hour.ago)
    doe = Organization.create!(name: FUNDER, verification_status: "verified", verified_by: "human:tosin")
    company = Organization.create!(name: "Imaginary Fission Co", verification_status: "verified", verified_by: "human:tosin")
    @link = Relationship.create!(from_organization: doe, to_organization: company, relationship_type: "funds", description: "Pending.")
    first = claim(FIRST, run: crawl_run!("crawl", 2.days.ago))
    assert DataQuality::Review.approve([ first.id ], by: "human:tosin").sole.ok?
    CrawlRun.create!(stage: "match", source_kind: "usaspending_doe_awards", status: "succeeded", started_at: 1.hour.ago,
      stats: { "dropped_checked_source_ids" => [ @source.id ] })
    @claim = claim(SECOND, run: crawl_run!("crawl", 1.hour.ago))
    crawl_run!("verify", 1.hour.ago)
    sign_in_as users(:admin)
  end

  def crawl_run!(stage, at) = CrawlRun.create!(stage:, source_kind: "usaspending_doe_awards", status: "succeeded", started_at: at)

  def claim(description, run:)
    Candidate.create!(source: @source, kind: "relationship", status: "matched", quote: "award #{Candidate.count}", crawl_run: run,
      payload: { "relationship_type" => "funds", "description" => description }, subject_type: "Relationship", subject_id: @link.id,
      ai_recommendation: "recommend_publish", ai_confidence: 0.95, ai_source_sha256: @source.content_sha256)
  end

  def with_s1(enabled:, &)
    config = SafeClasses::CONFIG.deep_dup
    config["classes"]["S1"]["enabled"] = enabled
    config["cap"]["max_share"] = 1.0 # one DOE link here
    stub_const(SafeClasses, :CONFIG, config.freeze, &)
  end

  test "while S1 is off, its items show as what Accept would take, and there's nothing to accept" do
    with_s1(enabled: false) do
      get admin_recommendations_path

      assert_select "#safe-#{@claim.id} .nd-tag", "Would be safe: S1"
      assert_select "#safe-#{@claim.id}", /Description.*1 award.*→.*2 awards/m
      assert_select "form[action=?]", admin_recommendations_accept_path, count: 0
    end
  end

  test "with S1 on, Accept takes it in the same click, recorded as the verifier's recommendation" do
    with_s1(enabled: true) do
      get admin_recommendations_path
      assert_select "#safe-#{@claim.id} .nd-tag", "Safe: S1"
      assert_select "#accept-heading .type-count", "1"
      shown = DataQuality::Recommendations.plan.fingerprint

      post admin_recommendations_accept_path, params: { shown: }
    end

    assert_redirected_to admin_recommendations_path
    assert_equal "Accepted 1 recommendation.", flash[:notice]
    assert @claim.reload.status_merged?
    assert_equal SECOND, @link.reload.description
  end

  test "a click on a page from before the safe item appeared accepts nothing" do
    stale = with_s1(enabled: false) { DataQuality::Recommendations.plan.fingerprint }

    with_s1(enabled: true) { post admin_recommendations_accept_path, params: { shown: stale } }

    assert_match "The list changed since you opened it", flash[:alert]
    assert @claim.reload.status_matched?
  end
end
