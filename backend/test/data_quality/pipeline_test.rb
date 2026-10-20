require "test_helper"
require_relative "support/fake_directory"
require_relative "support/dummy_plugin"

class DataQuality::PipelineTest < ActiveSupport::TestCase
  include ReviewHelpers

  setup do
    @lookup = FakeDirectory::Lookup.new(organizations: { "Acme Nuclear" => 7 })
    @writer = FakeDirectory::FactWriter.new
    @directory = FakeDirectory.client(lookup: @lookup, fact_writer: @writer)
  end

  def run_pipeline(**options)
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, directory: @directory, **options)
  end

  def dummy_candidates = Candidate.where(source: Source.where(source_kind: "dummy")).order(:id)

  test "a dummy plug-in runs through every stage; verify recommends, a human approves via FactWriter" do
    runs = run_pipeline(verifier: PublishEverything.new)

    assert_equal %w[crawl extract match verify], runs.map(&:stage)
    assert runs.all?(&:succeeded?)
    assert runs.all? { |run| run.source_kind == "dummy" && run.finished_at }
    assert_equal({ "sources" => 1, "candidates" => 2, "unchanged" => 0, "empty" => 0 }, runs[1].stats)
    assert_equal 1, runs[2].stats["matched"]
    assert_equal 1, runs[2].stats["proposed"]
    assert_equal 2, runs[3].stats["recommended"]

    existing, created = dummy_candidates
    assert existing.status_matched?, "verify doesn't publish"
    assert_equal [ "recommend_publish", 0.9, runs.last ], [ existing.ai_recommendation, existing.ai_confidence.to_f, existing.verify_run ]
    assert @writer.writes.none? { |write| write[:verification] }, "nothing verified yet"

    results = approve_recommended(directory: @directory)

    assert results.all?(&:ok?)
    assert existing.reload.status_merged?
    assert_equal [ "Organization", 7 ], [ existing.subject_type, existing.subject_id ]
    assert created.reload.status_merged?
    assert_equal 1001, created.subject_id, "approving publishes the record match proposed"

    match_writes, approve_writes = @writer.writes.partition { |write| write[:verification].nil? }
    assert_equal [ { name: "NewCo Fission" } ], match_writes.map { |w| w[:attributes] },
      "match proposes the new one; attaching to the existing one writes nothing"

    assert_equal 2, approve_writes.size
    write = approve_writes.first
    assert_equal "organization", write[:kind]
    assert_equal({ id: 7, aliases: [ "Acme Nuclear" ] }, write[:attributes],
      "an approved match keeps its own name and gains the one it was found under as an alias")
    evidence = write[:evidence].sole
    assert_equal [ "crawler", existing.source_id, "Acme Nuclear", 0.9 ],
      [ evidence[:found_by], evidence[:source_id], evidence[:quote], evidence[:confidence].to_f ]
    assert_equal runs.last.id, evidence[:crawl_run_id], "the run that judged it"
    assert_equal({ status: "verified", by: "human:tosin", context: { "candidate_id" => existing.id, "crawl_run_id" => runs.last.id, "edited" => false } },
      write[:verification])
    assert_equal 1001, approve_writes.second[:attributes][:id]
  end

  test "with the review-everything verifier nothing is published" do
    run_pipeline(verifier: DataQuality::Verifiers::ReviewEverything.new)

    assert dummy_candidates.all?(&:status_needs_review?)
    assert @writer.writes.none? { |write| write[:verification] }, "only pending writes, nothing verified"
  end

  test "a write the directory rejects: the proposal goes to review at match, an approval returns the error" do
    @directory = FakeDirectory.client(lookup: @lookup, fact_writer: FakeDirectory::FactWriter.new(fail_with: "name taken"))

    match = run_pipeline(verifier: PublishEverything.new)[2]
    assert_equal 1, match.stats["write_errors"], "the proposal fails at match"
    existing, proposed = dummy_candidates
    assert proposed.status_needs_review?
    assert_match "name taken", proposed.notes

    result = approve_recommended(directory: @directory).sole

    assert_equal existing.id, result.candidate_id
    assert_not result.ok?
    assert_equal [ "name taken" ], result.errors
    assert existing.reload.status_matched?, "a failed approval changes nothing; the admin shows the error"
  end

  test "extract skips content it has already processed" do
    run_pipeline(only: %w[crawl extract])
    rerun = run_pipeline(only: "extract").sole

    assert_equal({ "sources" => 0, "candidates" => 0, "unchanged" => 1, "empty" => 0 }, rerun.stats)
    assert_equal 2, dummy_candidates.count
  end

  test "changed content is extracted again, replacing unprocessed candidates" do
    run_pipeline(only: %w[crawl extract])
    source = Source.find_by!(url: DummyPlugin::URL)
    source.update!(content_text: "new text", content_sha256: Digest::SHA256.hexdigest("new text"))

    run_pipeline(only: "extract")

    assert_equal 2, dummy_candidates.count
    assert dummy_candidates.all?(&:status_new?)
    assert_equal source.content_sha256, source.reload.extracted_sha256
  end

  test "a candidate a person reopened isn't replaced on re-extraction, so its reopenings stay (#228)" do
    run_pipeline(only: %w[crawl extract])
    source = Source.find_by!(url: DummyPlugin::URL)
    reopened = dummy_candidates.first
    reopened.update!(reopenings: [ { "by" => "human:tosin", "reason" => "rejected by mistake" } ])
    source.update!(content_text: "new text", content_sha256: Digest::SHA256.hexdigest("new text"))

    run_pipeline(only: "extract")

    assert_equal [ "rejected by mistake" ], reopened.reload.reopenings.map { |r| r["reason"] }
    assert_equal 3, dummy_candidates.count, "the other one was replaced; this one stays beside the new two"
  end

  test "a failing stage is recorded and stops the pipeline" do
    broken = DummyPlugin.new
    def broken.crawl(_run) = raise("site is down")

    error = assert_raises(RuntimeError) do
      DataQuality::Pipeline.run("dummy", plugin: broken, directory: @directory)
    end

    assert_equal "site is down", error.message
    run = CrawlRun.where(source_kind: "dummy").sole
    assert run.failed?
    assert_equal "RuntimeError: site is down", run.error
  end

  test "unknown stages and source kinds are refused" do
    assert_raises(ArgumentError) { run_pipeline(only: "publish") }
    assert_raises(DataQuality::Plugin::UnknownSourceKind) { DataQuality::Plugin.for("no_such_source") }
  end
end
