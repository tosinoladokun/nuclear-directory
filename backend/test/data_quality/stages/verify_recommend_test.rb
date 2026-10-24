require "test_helper"
require_relative "../support/dummy_plugin"

# Verify only recommends (#15, Tosin: "I should have the final approval to
# publish"). Against the real directory.
class DataQuality::Stages::VerifyRecommendTest < ActiveSupport::TestCase
  include ReviewHelpers

  # Counts what it's asked, and publishes everything.
  class CountingVerifier
    attr_reader :asked

    def initialize = @asked = []

    def call(candidate)
      @asked << candidate.id
      DataQuality::Verdict.new(outcome: :publish, confidence: 0.85, reason: "The row names it.")
    end
  end

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/recommend.html", source_kind: "dummy", crawl_status: "ok")
  end

  def candidate(kind, payload) = Candidate.create!(source: @source, kind: kind, payload: payload, quote: "a quote")
  def run_stage(stage, **) = DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: stage, **).last

  test "a confident verdict is stored as a recommendation, and nothing is written to the directory" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    proposed = Organization.find(c.reload.subject_id)
    events = VerificationEvent.count

    verify = run_stage("verify", verifier: CountingVerifier.new)

    c.reload
    assert c.status_matched?, "still waiting for a human"
    assert_equal [ "recommend_publish", 0.85, "The row names it.", verify.id ],
      [ c.ai_recommendation, c.ai_confidence.to_f, c.ai_reason, c.verify_run_id ]
    assert c.ai_checked_at
    assert_equal 1, verify.stats["recommended"]
    assert proposed.reload.pending?, "not published"
    assert_empty proposed.evidence.where(crawl_run_id: verify.id)
    assert_equal events, VerificationEvent.count, "no verification decision was made"
    assert_includes Candidate.recommended, c
  end

  test "a later run doesn't ask the model again about a recommended candidate, but repeats the code checks" do
    kept = candidate("organization", { "name" => "Imaginary Fission Co" })
    closed = candidate("organization", { "name" => "Another Fission Co" })
    run_stage("match")
    run_stage("verify", verifier: CountingVerifier.new)
    first_run = kept.reload.verify_run_id
    Organization.find(closed.reload.subject_id).reject!(by: "human:tosin")
    verifier = CountingVerifier.new

    again = run_stage("verify", verifier:)

    assert_empty verifier.asked, "no second model call"
    assert_equal [ "recommend_publish", first_run ], [ kept.reload.ai_recommendation, kept.verify_run_id ]
    assert_equal 1, again.stats["already_recommended"]
    assert closed.reload.status_needs_review?, "a human rejected its record since"
    assert_match "was rejected by human:tosin", closed.notes
  end

  test "a candidate held by a code check records no model, since none was asked" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ")
    unit.verify!(by: "human:tosin")
    held = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    asked = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")

    # Records its model on the run while answering, as the OpenRouter client does.
    batch = Object.new
    def batch.verdicts(candidates, run:, plugin:)
      run.update!(model: "vendor/verifier")
      candidates.to_h { |c| [ c.id, DataQuality::Verdict.new(outcome: :publish, confidence: 0.9, reason: "Yes.") ] }
    end

    verify = run_stage("verify", verifier: batch)

    assert_nil held.reload.ai_model
    assert_equal verify.id, held.verify_run_id
    assert_equal [ "recommend_publish", "vendor/verifier" ], [ asked.reload.ai_recommendation, asked.ai_model ]
  end

  test "values are compared as the directory stores them: a padded docket or lowercase country isn't a conflict" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", country_code: "US")
    unit.verify!(by: "human:tosin")
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => " 05000354 ", "country_code" => " us " })
    c.update!(status: "matched", subject_type: "Facility", subject_id: unit.id)

    run_stage("verify", verifier: CountingVerifier.new)

    assert_equal "recommend_publish", c.reload.ai_recommendation
  end

  test "a human's decision made while the model is asked is never overwritten" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    # Approves the candidate in the admin mid-run, then answers "review".
    racing = Object.new
    def racing.verdicts(candidates, run:, plugin:)
      DataQuality::Review.approve(candidates.map(&:id), by: "human:tosin")
      candidates.to_h { |x| [ x.id, DataQuality::Verdict.new(outcome: :review, reason: "Unsure.") ] }
    end

    verify = run_stage("verify", verifier: racing)

    assert c.reload.status_merged?, "the approval stands"
    assert_nil c.ai_recommendation
    assert_equal 1, verify.stats["decided_meanwhile"]
  end

  test "a recommendation lapses when its source changes, and verify asks again" do
    @source.update!(content_text: "Imaginary Fission Co, the old page", content_sha256: "old")
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    c.update!(quote: "Imaginary Fission Co")
    run_stage("match")
    run_stage("verify", verifier: CountingVerifier.new)
    assert_equal "old", c.reload.ai_source_sha256
    assert_includes Candidate.recommended, c

    @source.update!(content_text: "Imaginary Fission Co, the new page", content_sha256: "new")
    assert_not_includes Candidate.recommended, c, "not approvable as recommended against a page the verifier never read"

    verifier = CountingVerifier.new
    again = run_stage("verify", verifier:)

    assert_equal [ c.id ], verifier.asked
    assert_equal [ "recommend_publish", "new", again.id ], [ c.reload.ai_recommendation, c.ai_source_sha256, c.verify_run_id ]
  end

  test "a recommended candidate whose source changes during the run waits for the next run" do
    other = Source.create!(url: "https://www.nrc.gov/test/other.html", source_kind: "dummy", crawl_status: "ok")
    kept = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    run_stage("verify", verifier: CountingVerifier.new)
    asked = Candidate.create!(source: other, kind: "organization", payload: { "name" => "Another Fission Co" }, quote: "q")
    run_stage("match")
    source = @source
    # A new snapshot of the first source arrives while the model is asked about the other.
    changing = Object.new
    changing.define_singleton_method(:verdicts) do |candidates, run:, plugin:|
      source.update!(content_sha256: "changed")
      candidates.to_h { |x| [ x.id, DataQuality::Verdict.new(outcome: :publish, confidence: 0.9, reason: "Yes.") ] }
    end

    verify = run_stage("verify", verifier: changing)

    assert verify.succeeded?, "no crash on the missing verdict"
    assert_equal 1, verify.stats["source_changed"]
    assert_equal "recommend_publish", asked.reload.ai_recommendation
    assert_not_includes Candidate.recommended, kept.reload, "lapsed until the next run asks"
  end

  test "a value a human verifies while the model is asked is still compared before recommending" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354")
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    c.update!(status: "matched", subject_type: "Facility", subject_id: unit.id)
    # Verifies the record with another state mid-run, then recommends.
    racing = Object.new
    racing.define_singleton_method(:verdicts) do |candidates, run:, plugin:|
      unit.update!(state: "NJ")
      unit.verify!(by: "human:tosin")
      candidates.to_h { |x| [ x.id, DataQuality::Verdict.new(outcome: :publish, confidence: 0.9, reason: "Yes.") ] }
    end

    run_stage("verify", verifier: racing)

    assert c.reload.status_needs_review?, "not recommended over the new human-verified value"
    assert_match "human-verified state is NJ; this source says DE", c.notes
  end

  test "a verdict a code check produced records no model, even when the run asked one for others" do
    by_code = candidate("organization", { "name" => "Nothing Stored Co" })
    asked = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    mixed = Object.new
    def mixed.verdicts(candidates, run:, plugin:)
      run.update!(model: "vendor/verifier")
      candidates.to_h do |x|
        verdict = x.payload["name"].start_with?("Nothing") ?
          DataQuality::Verdict.new(outcome: :review, reason: "Nothing stored.", by_code: true) :
          DataQuality::Verdict.new(outcome: :publish, confidence: 0.9, reason: "Yes.")
        [ x.id, verdict ]
      end
    end

    run_stage("verify", verifier: mixed)

    assert_nil by_code.reload.ai_model
    assert_equal "vendor/verifier", asked.reload.ai_model
  end

  test "a company on a human-verified record: its domain or website is compared as a host" do
    terrapower = organizations(:terrapower)
    terrapower.verify!(by: "human:tosin")
    same = candidate("organization", { "name" => "TerraPower", "domain" => "WWW.TerraPower.com" })
    elsewhere = candidate("organization", { "name" => "TerraPower", "website" => "https://other.example/terrapower" })
    [ same, elsewhere ].each { |c| c.update!(status: "matched", subject_type: "Organization", subject_id: terrapower.id) }

    run_stage("verify", verifier: CountingVerifier.new)

    assert_equal "recommend_publish", same.reload.ai_recommendation, "www and case don't make a different domain"
    assert elsewhere.reload.status_needs_review?, "a website on another domain disagrees"
    assert_equal "human-verified domain is terrapower.com; this source says other.example", elsewhere.notes
  end

  # #402: a company matched by name whose stored CIK differs from the
  # source's goes to review, not through as a conflict that approval
  # only surfaces. Equivalent CIKs ("320193" vs "0000320193") compare
  # equal through Organization.cik_from.
  test "a company on a human-verified record: a different sec_cik goes to review, equivalent CIKs don't" do
    terrapower = organizations(:terrapower)
    terrapower.update!(sec_cik: "0000320193")
    terrapower.verify!(by: "human:tosin")
    conflict = candidate("organization", { "name" => "TerraPower", "sec_cik" => "0001820953" })
    equivalent = candidate("organization", { "name" => "TerraPower", "sec_cik" => "320193" })
    [ conflict, equivalent ].each { |c| c.update!(status: "matched", subject_type: "Organization", subject_id: terrapower.id) }

    run_stage("verify", verifier: CountingVerifier.new)

    assert conflict.reload.status_needs_review?
    assert_match "human-verified SEC CIK is 0000320193; this source says 0001820953", conflict.notes
    assert_equal "recommend_publish", equivalent.reload.ai_recommendation, "320193 and 0000320193 are the same CIK"
  end

  test "a candidate disagreeing with a human-verified record goes to review with both values, unasked" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", facility_type: "power_reactor")
    unit.verify!(by: "human:tosin")
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE",
      "facility_type" => "power_reactor" })
    run_stage("match")
    assert_equal unit.id, c.reload.subject_id
    verifier = CountingVerifier.new

    verify = run_stage("verify", verifier:)

    assert_empty verifier.asked, "no model call for a known conflict"
    assert c.reload.status_needs_review?
    assert_equal "human-verified state is NJ; this source says DE", c.notes
    assert_equal "needs_review", c.ai_recommendation
    assert_equal 1, verify.stats["conflicts"]
    assert_equal "NJ", unit.reload.state, "nothing written"
  end

  test "agreeing with a human-verified record is fine; names aren't compared" do
    unit = Facility.create!(name: "Hope Creek Generating Station", nrc_docket: "05000354", state: "NJ")
    unit.verify!(by: "human:tosin")
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "NJ" })
    run_stage("match")

    run_stage("verify", verifier: CountingVerifier.new)

    assert_equal "recommend_publish", c.reload.ai_recommendation
  end

  test "approving publishes as the human, with the verifier's confidence on the evidence and the history" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    verify = run_stage("verify", verifier: CountingVerifier.new)

    result = approve_recommended(by: "human:tosin").sole

    assert result.ok?
    organization = Organization.find(c.reload.subject_id)
    assert c.status_merged?
    assert_equal [ true, "human:tosin" ], [ organization.verified?, organization.verified_by ]
    evidence = organization.evidence.find_by!(crawl_run_id: verify.id)
    assert_equal 0.85, evidence.confidence.to_f
    event = Directory::Lookup.verification_history(type: "Organization", id: organization.id).first
    assert_equal [ "verified", "human:tosin", c.id ], [ event.to_status, event.by, event.context["candidate_id"] ]
  end

  test "approving a candidate the verifier disputed doesn't record its confidence as support" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    disputing = Object.new
    def disputing.call(_) = DataQuality::Verdict.new(outcome: :review, confidence: 0.9, reason: "The source names someone else.")
    run_stage("verify", verifier: disputing)

    assert DataQuality::Review.approve([ c.id ], by: "human:tosin").sole.ok?

    evidence = Organization.find(c.reload.subject_id).evidence.where.not(crawl_run_id: nil).sole
    assert_nil evidence.confidence, "0.9 was confidence in the dispute, not in the fact"
  end

  test "approval is all or nothing: a failure after the write leaves the fact unpublished and the candidate waiting" do
    c = candidate("facility", { "name" => "Imaginary 1", "nrc_docket" => "05099999" })
    run_stage("match")
    run_stage("verify", verifier: CountingVerifier.new)
    failing = Class.new(DataQuality::DirectoryClient) do
      def fill_site_from_unit(*, **) = raise("database went away")
    end.new

    assert_raises(RuntimeError) { DataQuality::Review.approve([ c.id ], by: "human:tosin", directory: failing) }

    assert c.reload.status_matched?, "still waiting for approval"
    assert Facility.find(c.subject_id).pending?, "the write was rolled back"
  end

  test "only a human approves, and a decided candidate isn't approved again" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    run_stage("verify", verifier: CountingVerifier.new)

    assert_raises(ArgumentError) { DataQuality::Review.approve([ c.id ], by: "agent:verifier/x") }

    approve_recommended
    again = DataQuality::Review.approve([ c.id ], by: "human:tosin").sole
    assert_not again.ok?
    assert_match "already merged", again.errors.join
  end
end
