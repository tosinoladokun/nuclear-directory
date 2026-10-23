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
    assert_select "p", /No “Approve all” here: Joy agrees with 1 finding, but it changes what a person already decided/
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
end
