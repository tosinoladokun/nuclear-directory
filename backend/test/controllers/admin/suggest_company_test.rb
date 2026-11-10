require "test_helper"

# Add a lead (#752): a company name, website or link on Tosin's inbox becomes a
# lead in the one pipeline; its state shows on the inbox, one line each.
class Admin::SuggestCompanyTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  Found = Data.define(:outcome, :organization_id, :candidate_id, :reason, :name, :website)

  setup do
    sign_in_as users(:admin)
    @finder = LeadFindJob.finder
  end

  teardown { LeadFindJob.finder = @finder }

  def add(text) = post(admin_inbox_suggest_path, params: { suggestion: text })
  def line(lead) = css_select("#lead-#{lead.id}").text.squish

  test "Add queues the find and shows Finding; an empty or too long one is refused" do
    assert_enqueued_with(job: LeadFindJob) { add("  Kairos Power ") }
    lead = Lead.find_by!(normalized_name: "kairos power")
    assert_equal [ "company", "new", "human:tosin" ], lead.values_at(:kind, :status, :decided_by)
    follow_redirect!
    assert_select "label", text: "Add a lead"
    assert_select "input[type=submit][value=Add]"
    assert_equal "Kairos Power Finding", line(lead)

    assert_no_enqueued_jobs { add(" ") }
    assert_no_enqueued_jobs { add("x" * 501) }
    assert_no_enqueued_jobs { add((1..51).map { |n| "Company #{n}" }.join("\n")) }
  end

  test "several at once, one per line; blank and repeated lines skipped" do
    assert_enqueued_jobs(3, only: LeadFindJob) { add("Alpha Fission\n\nhttps://betafusion.example\n Gamma Isotopes \nAlpha Fission") }
    assert_equal [ "Alpha Fission", "betafusion.example", "Gamma Isotopes" ].sort, Lead.where(status: "new").pluck(:name).sort
    assert_equal "Added 3 leads. They're being found now.", flash[:notice]
  end

  test "the same lead again while it's being found isn't queued twice" do
    assert_enqueued_jobs(1, only: LeadFindJob) { 2.times { add("Kairos Power") } }
    travel(6.minutes) { assert_enqueued_jobs(1, only: LeadFindJob) { add("Kairos Power") } }
  end

  test "a link is kept as the lead's source, named by its site and path: two pages on one site are two leads" do
    add("https://www.linkedin.com/company/oklo-inc/\nhttps://www.linkedin.com/company/kairos-power/")
    oklo = Lead.find_by!(name: "linkedin.com/company/oklo-inc")
    assert_equal "https://www.linkedin.com/company/oklo-inc/", oklo.sources.sole["url"]
    assert Lead.exists?(name: "linkedin.com/company/kairos-power")
  end

  test "Your leads shows the last two weeks by when Tosin added them, not when a source last mentioned them" do
    add("Old Lead Co")
    lead = Lead.find_by!(normalized_name: "old lead co")
    lead.update!(sources: lead.sources.map { |s| s.merge("first" => 20.days.ago.to_date.iso8601, "last" => 20.days.ago.to_date.iso8601) })
    Lead.sighted!(name: "Old Lead Co", kind: "company", key: "news:x", label: "A press release")
    assert_not CompanySuggestion.shown.exists?(id: lead.id)
  end

  test "states, one line each: finding until a sourced role, waiting for check, in your inbox, already listed, couldn't confirm" do
    known = Organization.create!(name: "Oklo", verification_status: "verified", verified_by: "human:tosin")
    page = Source.create!(url: "https://newfission.example", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "q")
    claim = Candidate.create!(source: page, kind: "organization", status: "needs_review", payload: { "name" => "New Fission" }, quote: "q")
    results = {
      "New Fission" => Found.new(outcome: :proposed, organization_id: nil, candidate_id: claim.id, reason: nil, name: "New Fission", website: page.url),
      "Oklo" => Found.new(outcome: :duplicate, organization_id: known.id, candidate_id: nil, reason: nil, name: "Oklo", website: nil),
      "Bakery Co" => Found.new(outcome: :unconfirmed, organization_id: nil, candidate_id: nil, reason: "no nuclear work on its site", name: "Bakery Co",
        website: "https://bakery.example")
    }
    LeadFindJob.finder = ->(lead) { results.fetch(lead.name) }
    perform_enqueued_jobs { results.each_key { |name| add(name) } }

    get admin_inbox_path
    leads = Lead.where(name: results.keys).index_by(&:name)
    assert_equal "New Fission Finding", line(leads["New Fission"]), "no company with a sourced role yet: still being filled in"
    new_co = Organization.create!(name: "New Fission", verification_status: "pending")
    claim.update!(status: "matched", subject_type: "Organization", subject_id: new_co.id, proposed_subject: true)
    assert_equal "Finding", LeadFinding.state(leads["New Fission"].reload), "its company has no sourced role yet (#638)"
    give_sourced_role(new_co)
    get admin_inbox_path
    assert_equal "New Fission In your inbox Show", line(leads["New Fission"]), "a sourced role and nothing for Data Quality to settle"
    assert_match "Oklo Already listed", line(leads["Oklo"])
    assert_select "#lead-#{leads['Oklo'].id} a[href=?]", admin_fact_path(type: "Organization", id: known.id)
    assert_equal "Bakery Co Couldn't confirm: no nuclear work on its site: found Bakery Co, https://bakery.example", line(leads["Bakery Co"])

    lead = leads["New Fission"]
    review = DataQuality::Review.singleton_class
    review.alias_method :real_inbox_kind, :inbox_kind
    review.define_method(:inbox_kind) { |*, **| "dq" }
    assert_equal "Waiting for check", LeadFinding.state(lead.reload), "Data Quality's to settle first"
    review.define_method(:inbox_kind) { |*, **| "new_record" }
    get admin_inbox_path
    assert_select "#lead-#{lead.id} a[href=?]", "#inbox-item-#{claim.id}"
  ensure
    if review&.method_defined?(:real_inbox_kind)
      review.alias_method :inbox_kind, :real_inbox_kind
      review.remove_method :real_inbox_kind
    end
  end

  test "a claim decided: Created or Said no" do
    page = Source.create!(url: "https://decided.example", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "q")
    lead = Lead.sighted!(name: "Decided Co", kind: "company", key: "admin:suggest:decided co", label: CompanySuggestion::LABEL)
    company = Organization.create!(name: "Decided Co", verification_status: "verified", verified_by: "human:tosin")
    claim = Candidate.create!(source: page, kind: "organization", status: "merged", payload: { "name" => "Decided Co" }, quote: "q",
      subject_type: "Organization", subject_id: company.id)
    lead.update!(status: "added", candidate: claim)
    assert_equal "Created", LeadFinding.state(lead)
    claim.update!(status: "rejected", reviewed_by: "human:tosin")
    assert_equal "Said no", LeadFinding.state(lead.reload)
  end

  test "a finder that fails leaves Couldn't confirm and a retry next week, not Finding forever" do
    LeadFindJob.finder = ->(*) { raise Timeout::Error }
    add("Stuck Co")
    perform_enqueued_jobs
    lead = Lead.find_by!(normalized_name: "stuck co")
    assert_equal "Couldn't confirm", LeadFinding.state(lead)
    assert_equal [ "researching", 1 ], lead.values_at(:status, :find_attempts)
    assert_in_delta 1.week.from_now, lead.next_find_at, 1.minute
  end

  test "its claim closed at Data Quality's check closes the lead with the reason; Tosin's No closes it as Said no" do
    page = Source.create!(url: "https://closed.example", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: "q")
    leads = %w[Dup\ Co Nope\ Co].map do |name|
      claim = Candidate.create!(source: page, kind: "organization", status: "needs_review", payload: { "name" => name }, quote: "q")
      Lead.sighted!(name:, kind: "company", key: "admin:suggest:#{name.downcase}", label: CompanySuggestion::LABEL).tap { |l| l.update!(status: "added", candidate: claim) }
    end
    leads.first.candidate.update!(status: "rejected", reviewed_by: "agent:dq", dq_reason: "duplicate of Oklo")
    leads.last.candidate.update!(status: "rejected", reviewed_by: "human:tosin")
    assert_equal [ "ignored", "Closed at check: duplicate of Oklo" ], [ leads.first.reload.status, LeadFinding.state(leads.first) ]
    assert_equal [ "ignored", "Said no" ], [ leads.last.reload.status, LeadFinding.state(leads.last) ]
    get admin_inbox_path
    assert_select "#lead-#{leads.first.id}", text: /Dup Co Closed at check: duplicate of Oklo/
    assert_select "#lead-#{leads.last.id}", count: 0
  end
end
