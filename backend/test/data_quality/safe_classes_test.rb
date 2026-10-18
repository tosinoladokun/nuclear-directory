require "test_helper"

# Safe classes (#306, option A): the verifier's recommendations Accept
# takes without Data Quality's list. One test per gate, and S1's own.
class DataQuality::SafeClassesTest < ActiveSupport::TestCase
  SafeClasses = DataQuality::SafeClasses
  FUNDER = "U.S. Department of Energy"
  FIRST = "1 award from the U.S. Department of Energy totaling $1.0 million, 2021: DENE0000001."
  SECOND = "2 awards from the U.S. Department of Energy totaling $3.0 million (2021–2023): DENE0000001, DENE0000002."
  TEXT = "the award rows"

  setup do
    @source = Source.create!(url: "https://api.usaspending.gov/test/recipient/1", source_kind: "usaspending_doe_awards", crawl_status: "ok",
      http_status: 200, content_text: TEXT, content_sha256: Digest::SHA256.hexdigest(TEXT))
    # The API index the crawl fetches; each recipient's page is stored from it.
    @index = Source.create!(url: "https://api.usaspending.gov/test/index", source_kind: "usaspending_api", crawl_status: "ok",
      http_status: 200, fetched_at: 1.hour.ago)
    @doe = Organization.create!(name: FUNDER, verification_status: "verified", verified_by: "human:tosin")
    @company = Organization.create!(name: "Imaginary Fission Co", verification_status: "verified", verified_by: "human:tosin")
    @link = Relationship.create!(from_organization: @doe, to_organization: @company, relationship_type: "funds", description: "Pending.")
    @first_run = crawl_run!("crawl", started_at: 2.days.ago)
    # The link as a first award claim wrote it, approved by a person.
    first = claim({ "description" => FIRST, "started_on" => "2021-01-01" }, crawl_run: @first_run)
    assert DataQuality::Review.approve([ first.id ], by: "human:tosin").sole.ok?
    @run = crawl_run!("crawl")
    crawl_run!("verify")
    crawl_run!("match", stats: { "dropped_check_skipped" => 3, "dropped_checked_source_ids" => [ @source.id ] })
  end

  def crawl_run!(stage, started_at: 1.hour.ago, stats: {}) =
    CrawlRun.create!(stage:, source_kind: "usaspending_doe_awards", status: "succeeded", started_at:, stats:)

  # A claim the verifier recommends now, attached to the link.
  def claim(payload, crawl_run: @run, confidence: 0.95, source: @source)
    Candidate.create!(source:, kind: "relationship", status: "matched", quote: "award #{Candidate.count}", crawl_run:,
      payload: { "relationship_type" => "funds", "from_organization" => { "name" => FUNDER }, "to_organization" => { "name" => @company.name } }.merge(payload),
      subject_type: "Relationship", subject_id: @link.id, ai_recommendation: "recommend_publish", ai_confidence: confidence,
      ai_source_sha256: source.content_sha256)
  end

  # S1 turned on, with the share cap out of the way unless a test sets it
  # (this directory has one DOE link, so 25% of it is no link at all).
  def with_config(enabled: true, max_items: 20, max_share: 1.0, &)
    config = SafeClasses::CONFIG.deep_dup
    config["classes"]["S1"]["enabled"] = enabled
    config["cap"] = { "max_items" => max_items, "max_share" => max_share }
    stub_const(SafeClasses, :CONFIG, config.freeze, &)
  end

  def item_for(candidate) = SafeClasses.items.find { |item| item.candidate_id == candidate.id }
  def why(candidate) = with_config { item_for(candidate).why }

  test "an award update on a link a person verified is safe, with what it changes" do
    candidate = claim({ "description" => SECOND, "started_on" => "2021-01-01" })

    with_config do
      item = item_for(candidate)
      assert item.taken?, item.why
      assert_equal "S1", item.klass
      assert_equal({ "description" => [ FIRST, SECOND ] }, item.changes)
    end
  end

  test "Accept takes it as a person's decision, with the class in the reason" do
    candidate = claim({ "description" => SECOND, "started_on" => "2021-01-01" })

    with_config do
      plan = DataQuality::Recommendations.plan
      assert_equal [ candidate.id ], plan.safe_accept.map(&:candidate_id)
      result = SafeClasses.accept(plan.safe_accept, by: "human:tosin").sole
      assert result.ok?, result.errors.to_sentence
    end

    assert candidate.reload.status_merged?
    assert_equal SECOND, @link.reload.description
    event = Directory::Lookup.verification_history(type: "Relationship", id: @link.id).first
    assert_equal [ "human:tosin", "Accepted the verifier's recommendation (safe class S1: USAspending update on a settled DOE link)", candidate.id, false ],
      [ event.by, event.reason, event.context["candidate_id"], event.context["edited"] ]
  end

  test "while S1 is off, the preview shows it as what Accept would take, and Accept takes nothing" do
    candidate = claim({ "description" => SECOND, "started_on" => "2021-01-01" })

    with_config(enabled: false) do
      plan = DataQuality::Recommendations.plan
      assert_equal [ candidate.id ], plan.safe_dry.map(&:candidate_id)
      assert_empty plan.safe_accept
      assert plan.nothing?
    end
  end

  test "one fingerprint covers both lists: a new safe item changes it" do
    with_config do
      before = DataQuality::Recommendations.plan.fingerprint
      claim({ "description" => SECOND, "started_on" => "2021-01-01" })
      refute_equal before, DataQuality::Recommendations.plan.fingerprint
    end
  end

  test "G1: the verifier's confidence must be at least 0.9" do
    assert_equal "the verifier's confidence is below 0.9", why(claim({ "description" => SECOND }, confidence: 0.85))
  end

  test "G1: a claim whose source changed since the verifier checked it isn't covered" do
    candidate = claim({ "description" => SECOND })
    @source.update!(content_sha256: "changed")

    with_config { assert_nil item_for(candidate) }
  end

  test "G2: a link no person verified isn't safe" do
    VerificationEvent.where(subject: @link).where("by LIKE 'human:%'").delete_all
    @link.update_columns(verified_by: "agent:verifier/test")

    assert_equal "no person has verified its link", why(claim({ "description" => SECOND }))
  end

  test "G2: a link whose company isn't public isn't safe" do
    @company.update_columns(verification_status: "unpublished")

    assert_equal "its link isn't verified and public", why(claim({ "description" => SECOND }))
  end

  test "G3: a description a person wrote isn't safe" do
    edited = DataQuality::DirectoryClient.new.decide_fact("relationship", id: @link.id, status: "verified", by: "human:tosin",
      reason: "Hand-written", attributes: { description: "ARDP award: hand-written." })
    assert edited.success?

    assert_equal "it changes a value a person wrote", why(claim({ "description" => SECOND }))
  end

  test "G3: a field outside S1 isn't safe, and nor is a claim that changes nothing" do
    assert_equal "it changes ended on, not only description or started on", why(claim({ "description" => SECOND, "ended_on" => "2023-01-01" }))
    assert_equal "it changes nothing", why(claim({ "description" => FIRST }))
  end

  test "G4: another claim waiting for review on the same link, or an open correction report, isn't safe" do
    waiting = claim({ "description" => "Something else." })
    waiting.update_columns(status: "needs_review", review_origin: "dropped")
    candidate = claim({ "description" => SECOND })
    assert_equal "another claim on its link waits for review", why(candidate)

    waiting.update_columns(status: "rejected")
    CorrectionReport.create!(subject: @company.name, page_path: "/companies/#{@company.slug}?ref=x", message: "The DOE total is wrong.")
    assert_equal "a correction report on its page isn't resolved", why(candidate)
  end

  test "G5: a first batch, a failed fetch or a match run that skipped the dropped check isn't safe" do
    assert_equal DataQuality::Review::FIRST_BATCH, why(claim({ "description" => SECOND }, crawl_run: @first_run))

    candidate = claim({ "description" => SECOND })
    @source.update_columns(http_status: 503)
    assert_equal "its source's last fetch didn't return 200", why(candidate)

    @source.update_columns(http_status: 200)
    other = Source.create!(url: "https://api.usaspending.gov/test/recipient/9", source_kind: "usaspending_doe_awards", crawl_status: "ok")
    crawl_run!("match", started_at: 1.minute.ago, stats: { "dropped_check_skipped" => 1, "dropped_checked_source_ids" => [ other.id ] })
    assert_equal "the last match run didn't check its source for dropped facts", why(candidate),
      "the skip that counts is the claim's own source's; others skipped (setup's run) don't block it"
  end

  test "G5: the latest crawl or match attempt counts, whatever its status, and so does the API index's last fetch" do
    candidate = claim({ "description" => SECOND })
    assert_nil why(candidate)

    @index.update_columns(http_status: 503, fetched_at: Time.current)
    assert_equal "the source's last fetch didn't return 200", why(candidate), "a failed API fetch leaves the recipient's page as it was"

    @index.update_columns(http_status: 200)
    failed = CrawlRun.create!(stage: "crawl", source_kind: "usaspending_doe_awards", status: "failed", started_at: 1.minute.ago)
    assert_equal "the source's last crawl didn't finish", why(candidate)

    failed.update_columns(status: "succeeded")
    CrawlRun.create!(stage: "match", source_kind: "usaspending_doe_awards", status: "running", started_at: Time.current)
    assert_equal "the last match run didn't finish", why(candidate)
  end

  test "G4: a correction report filed at a company's old address still counts" do
    candidate = claim({ "description" => SECOND })
    CorrectionReport.create!(subject: @company.name, page_path: "/companies/#{@company.slug}", message: "The DOE total is wrong.")
    @company.update!(slug: "imaginary-fission")

    assert_equal "a correction report on its page isn't resolved", why(candidate)
  end

  test "G6: a run proposing more safe changes than the cap gets none of them" do
    other = Organization.create!(name: "Other Fission Co", verification_status: "verified", verified_by: "human:tosin")
    second_link = Relationship.create!(from_organization: @doe, to_organization: other, relationship_type: "funds")
    first = Candidate.create!(source: @source, kind: "relationship", status: "matched", quote: "other award", crawl_run: @first_run,
      payload: { "relationship_type" => "funds", "description" => FIRST }, subject_type: "Relationship", subject_id: second_link.id,
      ai_recommendation: "recommend_publish", ai_confidence: 0.95, ai_source_sha256: @source.content_sha256)
    assert DataQuality::Review.approve([ first.id ], by: "human:tosin").sole.ok?
    a = claim({ "description" => SECOND })
    b = Candidate.create!(source: @source, kind: "relationship", status: "matched", quote: "other award 2", crawl_run: @run,
      payload: { "relationship_type" => "funds", "description" => SECOND }, subject_type: "Relationship", subject_id: second_link.id,
      ai_recommendation: "recommend_publish", ai_confidence: 0.95, ai_source_sha256: @source.content_sha256)

    with_config(max_items: 1) do
      items = SafeClasses.items.select { |item| [ a.id, b.id ].include?(item.candidate_id) }
      assert_equal 2, items.size
      items.each { |item| assert_match(/\Aits run proposes 2 safe changes, over the limit of 1/, item.why) }
    end
    with_config(max_share: 0.5) do
      assert_match(/over the limit of 1 \(20, or 50% of the source's 2 public facts\)/, item_for(a).why)
    end
  end

  test "S1: an award total that drops by more than 20% isn't safe" do
    lower = FIRST.sub("$1.0 million", "$750,000")
    assert_equal "its award total may drop by more than 20%", why(claim({ "description" => lower }))
    assert_nil why(claim({ "description" => FIRST.sub("$1.0 million", "$900,000") }))
  end

  # The plug-in's summaries round: $1,340,000 → $1,060,000 is a 20.9% drop
  # that reads "$1.3 million" → "$1.1 million" (15.4%).
  test "S1: a drop that rounding could hide counts at its largest" do
    dollars = ->(amount) { DataQuality::Plugins::UsaspendingDoeAwards.new.send(:dollars, BigDecimal(amount)) }
    text = ->(amount) { "1 award from the U.S. Department of Energy totaling #{dollars.(amount)}, 2021: DENE0000001." }
    assert_equal [ "$1.3 million", "$1.1 million" ], [ dollars.("1340000"), dollars.("1060000") ]
    written = claim({ "description" => text.("1340000") }, crawl_run: @first_run)
    assert DataQuality::Review.approve([ written.id ], by: "human:tosin").sole.ok?

    assert_equal "its award total may drop by more than 20%", why(claim({ "description" => text.("1060000") }))
    assert_nil why(claim({ "description" => text.("1300000").sub("1.3", "1.2") })), "$1.3 → $1.2 million is at most 11.1%"
  end

  test "G6: what the run already had approved counts, so the cap can't be passed in two clicks" do
    other = Organization.create!(name: "Other Fission Co", verification_status: "verified", verified_by: "human:tosin")
    second_link = Relationship.create!(from_organization: @doe, to_organization: other, relationship_type: "funds")
    first = Candidate.create!(source: @source, kind: "relationship", status: "matched", quote: "other award", crawl_run: @first_run,
      payload: { "relationship_type" => "funds", "description" => FIRST }, subject_type: "Relationship", subject_id: second_link.id,
      ai_recommendation: "recommend_publish", ai_confidence: 0.95, ai_source_sha256: @source.content_sha256)
    assert DataQuality::Review.approve([ first.id ], by: "human:tosin").sole.ok?

    with_config(max_items: 1) do
      a = claim({ "description" => SECOND })
      item = item_for(a)
      assert item.taken?, item.why
      assert SafeClasses.accept([ item ], by: "human:tosin").sole.ok?

      b = Candidate.create!(source: @source, kind: "relationship", status: "matched", quote: "other award 2", crawl_run: @run,
        payload: { "relationship_type" => "funds", "description" => SECOND }, subject_type: "Relationship", subject_id: second_link.id,
        ai_recommendation: "recommend_publish", ai_confidence: 0.95, ai_source_sha256: @source.content_sha256)
      assert_match(/\Aits run proposes 2 safe changes \(1 already approved\), over the limit of 1/, item_for(b).why)
    end
  end

  test "G5: an API answer that couldn't be read, or a verify run still going, isn't safe" do
    candidate = claim({ "description" => SECOND })
    @index.update_columns(http_status: 200, status_reason: "the answer wasn't valid JSON", fetched_at: Time.current)
    assert_equal "the source's last fetch didn't return 200", why(candidate)

    @index.update_columns(status_reason: nil)
    CrawlRun.create!(stage: "verify", source_kind: "usaspending_doe_awards", status: "running", started_at: Time.current)
    assert_equal "the verifier is still checking this source", why(candidate)

    CrawlRun.where(stage: "verify", status: "running").update_all(status: "failed")
    assert_equal "the verifier's last run didn't finish", why(candidate), "a failed run keeps the recommendations it saved, a partial set"
  end

  test "G4: a report on a company merged into the link's company still counts" do
    candidate = claim({ "description" => SECOND })
    merged = Organization.create!(name: "Old Fission Holdings", verification_status: "verified", verified_by: "human:tosin")
    CorrectionReport.create!(subject: merged.name, page_path: "/companies/#{merged.slug}", message: "This is the same company as Imaginary Fission.")
    Directory::FactWriter.merge_organization(from_id: merged.id, into_id: @company.id, by: "human:tosin", reason: "Same company")
    assert merged.reload.unpublished?

    assert_equal "a correction report on its page isn't resolved", why(candidate)
  end

  test "Accept checks it again under the link's lock: a person's edit after the page loaded stops it" do
    candidate = claim({ "description" => SECOND })

    with_config do
      items = DataQuality::Recommendations.plan.safe_accept
      assert_equal [ candidate.id ], items.map(&:candidate_id)
      DataQuality::DirectoryClient.new.decide_fact("relationship", id: @link.id, status: "verified", by: "human:tosin",
        reason: "Hand-written", attributes: { description: "ARDP award: hand-written." })

      result = SafeClasses.accept(items, by: "human:tosin").sole
      assert_equal [ "it's no longer safe: it changes a value a person wrote" ], result.errors
    end
    assert candidate.reload.status_matched?
    assert_equal "ARDP award: hand-written.", @link.reload.description
  end

  test "a claim Data Quality has its own call on is left to its list" do
    candidate = claim({ "description" => SECOND })
    candidate.update!(dq_recommendation: "reject", dq_reason: "a subcontract", dq_by: "human:tosin", dq_at: Time.current)

    with_config { assert_nil item_for(candidate) }
  end
end
