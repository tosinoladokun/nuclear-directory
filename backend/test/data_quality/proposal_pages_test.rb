require "test_helper"

# #934: the page a Data Quality proposal cites is stored, so the verifier can
# check the quote against it.
class DataQuality::ProposalPagesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  QUOTE = "Holtec International is headquartered in Camden, New Jersey.".freeze

  setup do
    @fetcher = DataQuality::Fetcher.new(sleeper: ->(_) { })
    stub_request(:get, "https://holtec.example/robots.txt").to_return(status: 404)
    @page = Source.create!(url: "https://holtec.example/about", source_kind: "web_page")
  end

  def claim(source = @page, quote: QUOTE) = Candidate.create!(source:, kind: "organization", status: "new", quote:, payload: { "name" => "Holtec International" })

  test "due: a web page with nothing stored, or whose stored text lacks the new quote; not one that holds it, a person's to look at, or a crawled kind" do
    stored = Source.create!(url: "https://holtec.example/stored", source_kind: "web_page", content_text: "<p>#{QUOTE}</p>", content_sha256: "a")
    stale = Source.create!(url: "https://holtec.example/stale", source_kind: "web_page", content_text: "Old text.", content_sha256: "b")
    human = Source.create!(url: "https://holtec.example/robots-no", source_kind: "web_page", crawl_status: "needs_human")
    crawled = Source.create!(url: "https://www.nrc.gov/x.html", source_kind: "nrc_news")
    ids = [ claim, claim, claim(stored), claim(stale), claim(human), claim(crawled) ].map(&:id)

    assert_equal [ @page.id, stale.id ].sort, DataQuality::ProposalPages.due(ids).sort
  end

  test "store: the page is stored with its hash, so the quote is found in it" do
    stub_request(:get, @page.url).to_return(body: "<html><title>About Holtec</title><p>#{QUOTE}</p></html>", headers: { "Content-Type" => "text/html" })

    assert_equal({ @page.id => :changed }, DataQuality::ProposalPages.store([ @page.id ], fetcher: @fetcher))

    @page.reload
    assert_equal [ "ok", "About Holtec" ], [ @page.crawl_status, @page.title ]
    assert @page.content_sha256.present?
    assert DataQuality::Plugins::WebPage.new.quote_in_source?(@page, QUOTE)
  end

  test "store: a page that blocks fetching stays unstored, as today, and the rest are still fetched" do
    other = Source.create!(url: "https://holtec.example/other", source_kind: "web_page")
    stub_request(:get, @page.url).to_return(status: 403, body: "Access Denied")
    stub_request(:get, other.url).to_return(body: "<p>Other page.</p>", headers: { "Content-Type" => "text/html" })

    assert_equal({ @page.id => :blocked, other.id => :changed }, DataQuality::ProposalPages.store([ @page.id, other.id ], fetcher: @fetcher))
    assert_equal [ "blocked", nil ], @page.reload.values_at(:crawl_status, :content_text)
  end

  test "store: an error on one page is reported, not raised" do
    fetcher = Object.new.tap { |fake| def fake.get(*, **) = raise("boom") }
    assert_equal({ @page.id => :error }, DataQuality::ProposalPages.store([ @page.id ], fetcher:))
  end

  test "a changed page lapses an earlier recommendation on it, as for any source" do
    @page.update!(content_text: "Old text.", content_sha256: "old")
    earlier = claim(quote: "Old text.")
    earlier.update!(ai_recommendation: "recommend_publish", ai_source_sha256: "old")
    stub_request(:get, @page.url).to_return(body: "<p>#{QUOTE}</p>", headers: { "Content-Type" => "text/html" })

    DataQuality::ProposalPages.store(DataQuality::ProposalPages.due([ claim.id ]), fetcher: @fetcher)

    assert_not_equal earlier.reload.ai_source_sha256, @page.reload.content_sha256, "the next verify asks about it again"
  end

  # Answers review for every claim, so a test sees whether verify reached it.
  class ReviewEverything
    def call(_candidate) = DataQuality::Verdict.new(outcome: :review, reason: "checked")
  end

  def verify = DataQuality::Pipeline.run("web_page", only: "verify", verifier: ReviewEverything.new).last

  test "a verify run already queued leaves a claim whose page is waiting to be stored, then checks it once stored (Copilot)" do
    waiting = claim
    run = verify
    assert_equal [ "new", 1 ], [ waiting.reload.status, run.stats["awaiting_page"] ], "not sent to review for a page about to be stored"

    stub_request(:get, @page.url).to_return(body: "<p>#{QUOTE}</p>", headers: { "Content-Type" => "text/html" })
    DataQuality::ProposalPages.store([ @page.id ], fetcher: @fetcher)
    verify
    assert_equal [ "needs_review", "checked" ], waiting.reload.values_at(:status, :notes), "checked against the stored page"
  end

  test "a claim whose page fetch was tried and failed, or that waited past WAIT, is verified as before #934" do
    blocked = claim
    @page.update!(fetched_at: 1.minute.from_now, crawl_status: "blocked")
    assert_not DataQuality::ProposalPages.awaiting?(blocked.reload)

    late = claim(Source.create!(url: "https://holtec.example/late", source_kind: "web_page"))
    late.update!(created_at: (DataQuality::ProposalPages::WAIT + 1.minute).ago)
    assert_not DataQuality::ProposalPages.awaiting?(late)
  end

  test "store: a page that became a person's to look at after it was queued isn't fetched (Copilot)" do
    ids = DataQuality::ProposalPages.due([ claim.id ])
    @page.update!(crawl_status: "needs_human")

    assert_equal({ @page.id => :needs_human }, DataQuality::ProposalPages.store(ids, fetcher: @fetcher))
    assert_not_requested :get, @page.url
  end

  test "during a deploy's data steps the job waits and tries again, and doesn't verify yet (Copilot)" do
    original = DataQuality::WriteLock.method(:shared)
    DataQuality::WriteLock.define_singleton_method(:shared) { |&| raise DataQuality::WriteLock::Busy, "deploying" }
    assert_no_enqueued_jobs(only: DataQuality::RunJob) do
      assert_enqueued_with(job: DataQuality::ProposalPagesJob, args: [ [ @page.id ], [ "web_page" ] ]) do
        DataQuality::ProposalPagesJob.perform_now([ @page.id ], [ "web_page" ])
      end
    end
  ensure
    DataQuality::WriteLock.define_singleton_method(:shared, original) if original
  end

  test "the job stores the pages, then matches and verifies each kind, even when storing fails" do
    original = DataQuality::ProposalPages.method(:store)
    DataQuality::ProposalPages.define_singleton_method(:store) { |*| raise "boom" }
    assert_enqueued_with(job: DataQuality::RunJob, args: [ "web_page", { only: %w[match verify] } ]) do
      assert_raises(RuntimeError) { DataQuality::ProposalPagesJob.perform_now([ @page.id ], [ "web_page" ]) }
    end
  ensure
    DataQuality::ProposalPages.define_singleton_method(:store, original) if original
  end
end
