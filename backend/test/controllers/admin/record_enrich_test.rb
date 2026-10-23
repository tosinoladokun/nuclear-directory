require "test_helper"

# Enrich (#479): the button asks for a company's pages to be read; its
# findings are decided on its Enrich page (Tosin: "I should be able to
# confirm it"), through the same approval as Checks.
class Admin::RecordEnrichTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:admin)
    @company = Organization.create!(name: "Acme Fission", website: "https://www.acmefission.com/", domain: "acmefission.com",
      verification_status: "verified", verified_by: "human:tosin")
    @page = Source.create!(url: "https://www.acmefission.com/about", source_kind: "company_pages", crawl_status: "ok", content_sha256: "sha",
      content_text: "Acme Fission is headquartered in Austin.")
    # An earlier, decided batch: this one isn't the source kind's first (which waits for Data Quality).
    earlier = CrawlRun.create!(stage: "extract", source_kind: "company_pages", status: "succeeded", started_at: 2.days.ago)
    Candidate.create!(source: @page, crawl_run: earlier, kind: "organization", payload: { "name" => "Earlier" }, quote: "q", status: "rejected")
    run = CrawlRun.create!(stage: "extract", source_kind: "company_pages", status: "succeeded", started_at: 1.hour.ago)
    @agreed = Candidate.create!(source: @page, crawl_run: run, kind: "organization", payload: { "name" => "Acme Fission", "hq_city" => "Austin" },
      quote: "Acme Fission is headquartered in Austin.", status: "matched", subject_type: "Organization", subject_id: @company.id,
      ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    @unsure = Candidate.create!(source: @page, crawl_run: run, kind: "organization", payload: { "name" => "Acme Fission", "founded_year" => "2019" },
      quote: "Acme Fission is headquartered in Austin.", status: "needs_review", notes: "unsure", subject_type: "Organization", subject_id: @company.id,
      ai_recommendation: "needs_review", ai_source_sha256: "sha")
  end

  def enrich_path = admin_record_enrich_path(type: "Organization", id: @company.id)

  test "a company's page has Enrich; the button asks for its pages and queues the read" do
    get admin_record_path(type: "Organization", id: @company.id)
    assert_select "a[href=?]", enrich_path, text: "Enrich"

    assert_enqueued_with(job: DataQuality::RunJob, args: [ "company_pages" ]) { post enrich_path }
    assert @company.reload.enrich_requested_at
    follow_redirect!
    assert_select ".nd-panel", /Reading acmefission\.com now/
  end

  test "its findings, each with its quote, source and Joy's verdict, approved or rejected here" do
    get enrich_path
    assert_select "#finding-#{@agreed.id} .type-body-strong", "Headquarters city: Austin"
    assert_select "#finding-#{@agreed.id}", /“Acme Fission is headquartered in Austin\.”.*acmefission\.com.*✓ Joy: accept/m
    assert_select ".nd-panel a[href=?]", "https://www.acmefission.com/", text: "acmefission.com"
    assert_select ".nd-panel button.nd-btn--outline", "Read its pages"
    assert_select "p", "No Approve all here: these change what a person already decided, so approve them one at a time."
    assert_select "#finding-#{@unsure.id}", /Joy: check it/
    assert_select "#finding-#{@agreed.id} .nd-btn--primary", "Approve"

    post admin_record_enrich_decide_path(type: "Organization", id: @company.id, candidate_id: @unsure.id, decision: "reject")
    assert @unsure.reload.status_rejected?
    assert_equal "human:tosin", @unsure.reviewed_by
  end

  test "Approve all Joy agrees with takes only the list shown, only what Joy recommends, never a change to a decided record" do
    get enrich_path
    assert_select "button", text: /Approve all Joy agrees with/, count: 0 # the company was decided by a person: one at a time

    @company.update_columns(verification_status: "pending", verified_by: nil)
    VerificationEvent.where(subject: @company).delete_all
    get enrich_path
    assert_select "button", /Approve all Joy agrees with \(1\)/

    post admin_record_enrich_agreed_path(type: "Organization", id: @company.id), params: { ids: [ @agreed.id ], shown: "stale" }
    assert_match "The list changed since you opened it", flash[:alert]
    assert @agreed.reload.status_matched?

    post admin_record_enrich_agreed_path(type: "Organization", id: @company.id),
      params: { ids: [ @agreed.id ], shown: Admin::CandidatesController.fingerprint([ @agreed.id ]) }
    assert_equal "Approved 1 finding.", flash[:notice], flash[:alert]
    assert @agreed.reload.status_merged?
    assert @unsure.reload.status_needs_review?
  end

  test "a company with no website says to add one; another company's claims can't be decided here" do
    @company.update_columns(website: nil)
    get enrich_path
    assert_select ".nd-panel", /It has no website to read yet/

    other = Organization.create!(name: "Other Co")
    elsewhere = Candidate.create!(source: Source.create!(url: "https://other.example/x", source_kind: "web_page"), kind: "organization",
      payload: { "name" => "Other Co" }, quote: "q", status: "matched", subject_type: "Organization", subject_id: other.id)
    post admin_record_enrich_decide_path(type: "Organization", id: @company.id, candidate_id: elsewhere.id, decision: "approve")
    assert_response :not_found
  end

  test "a stock listing reads as one finding; approved, it's on the company's page with a Google Finance link" do
    listing = Candidate.create!(source: @page, kind: "organization", payload: { "name" => "Acme Fission", "exchange" => "NASDAQ", "ticker" => "ACME" },
      quote: "Acme Fission trades on NASDAQ under the symbol ACME.", status: "matched", subject_type: "Organization", subject_id: @company.id,
      ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    get enrich_path
    assert_select "#finding-#{listing.id} .type-body-strong", "Listed on NASDAQ as ACME"

    post admin_record_enrich_decide_path(type: "Organization", id: @company.id, candidate_id: listing.id, decision: "approve")
    assert_equal [ "NASDAQ", "ACME" ], @company.reload.values_at(:exchange, :ticker), flash[:alert]
    get admin_record_path(type: "Organization", id: @company.id)
    assert_select "a.whitespace-nowrap[href=?]", "https://www.google.com/finance/quote/ACME:NASDAQ", text: /Google Finance/
  end

  test "findings from its SEC record show on its Enrich page too" do
    @company.update_columns(sec_cik: "0001849056")
    edgar = Source.create!(url: "https://data.sec.gov/submissions/CIK0001849056.json", source_kind: "company_pages", crawl_status: "ok", content_sha256: "sha")
    found = Candidate.create!(source: edgar, kind: "organization", payload: { "name" => "Acme Fission", "legal_name" => "ACME FISSION INC." },
      quote: '"name":"ACME FISSION INC."', status: "matched", subject_type: "Organization", subject_id: @company.id, ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    get enrich_path
    assert_select "#finding-#{found.id} .type-body-strong", "Legal name: ACME FISSION INC."
  end

  test "a finding shows the value it would replace; a site that couldn't be read says so; older findings stay in Checks" do
    @company.update_columns(hq_city: "Dallas")
    get enrich_path
    assert_select "#finding-#{@agreed.id}", /Now: Dallas\. Approving replaces it\./

    Source.create!(url: "https://www.acmefission.com/", source_kind: "company_pages", crawl_status: "blocked", status_reason: "HTTP 403")
    @company.update_columns(enrich_requested_at: 10.minutes.ago, enriched_at: 5.minutes.ago)
    @agreed.update_columns(created_at: 1.hour.ago) # found by an earlier request
    get enrich_path
    assert_select ".nd-panel", /Its site couldn't be read .* ago: HTTP 403\./
    assert_select "#finding-#{@agreed.id}", 0, "a finding from before this request is left to Checks"
  end

  test "a funding round reads plainly and waits for a person, never in the shortcut" do
    round = Candidate.create!(source: @agreed.source, crawl_run: @agreed.crawl_run, kind: "deal_term", quote: "Acme Fission closed a $37 million Series B.",
      payload: { "organization" => { "name" => @company.name }, "link_type" => "Organization", "term_type" => "funding_round", "status" => "announced",
        "external_id" => "page:x#series b", "amount_usd" => "37000000.0", "round" => "Series B", "starts_on" => "2024-12-06" },
      status: "new", ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    get enrich_path
    assert_select "#finding-#{round.id} .type-body-strong", "Funding round: Series B, $37,000,000, 6 Dec 2024"
    assert_select "form[action=?] input[name='ids[]'][value=?]", admin_record_enrich_agreed_path(type: "Organization", id: @company.id), round.id.to_s, 0
  end

  test "two fields for a pending company are both approved in one Approve all; an unusable website isn't asked for" do
    @company.update_columns(verification_status: "pending", verified_by: nil)
    @unsure.update_columns(status: "matched", notes: nil, ai_recommendation: "recommend_publish")
    ids = [ @agreed.id, @unsure.id ].sort
    post admin_record_enrich_agreed_path(type: "Organization", id: @company.id), params: { ids:, shown: Admin::CandidatesController.fingerprint(ids) }
    assert_equal "Approved 2 findings.", flash[:notice], flash[:alert]
    assert_equal [ "Austin", 2019 ], [ @company.reload.hq_city, @company.founded_year ]

    @company.update_columns(website: "acmefission.com", enrich_requested_at: nil)
    assert_no_enqueued_jobs { post enrich_path }
    assert_nil @company.reload.enrich_requested_at
    assert_match "needs to start with https://", flash[:alert]
  end

  test "while its findings are being worked out, or after that failed, the page says so instead of 'Nothing waiting'" do
    Candidate.where(id: [ @agreed.id, @unsure.id ]).update_all(status: "rejected")
    @company.update_columns(enrich_requested_at: 10.minutes.ago, enriched_at: 5.minutes.ago)
    run = CrawlRun.create!(stage: "extract", source_kind: "company_pages", status: "running", started_at: 4.minutes.ago)
    get enrich_path
    assert_select "p", /Working out what they state now/
    run.update!(status: "failed", error: "model timeout")
    get enrich_path
    assert_select "p", /stopped with an error\. Read its pages again to retry\./
    assert_select "p", text: /Nothing waiting/, count: 0
  end
end
