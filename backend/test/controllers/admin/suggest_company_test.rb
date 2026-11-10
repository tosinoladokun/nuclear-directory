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
    assert_equal "Kairos Power Finding", line(lead)

    assert_no_enqueued_jobs { add(" ") }
    assert_no_enqueued_jobs { add("x" * 501) }
  end

  test "a link is kept as the lead's source, named by its site" do
    add("https://www.linkedin.com/company/oklo-inc/")
    lead = Lead.find_by!(normalized_name: "linkedin com")
    assert_equal "https://www.linkedin.com/company/oklo-inc/", lead.sources.sole["url"]
  end

  test "states, one line each: waiting for check, in your inbox, already listed, couldn't confirm" do
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
    assert_equal "New Fission Waiting for check", line(leads["New Fission"])
    assert_match "Oklo Already listed", line(leads["Oklo"])
    assert_select "#lead-#{leads['Oklo'].id} a[href=?]", admin_fact_path(type: "Organization", id: known.id)
    assert_equal "Bakery Co Couldn't confirm: no nuclear work on its site: found Bakery Co, https://bakery.example", line(leads["Bakery Co"])

    lead = leads["New Fission"]
    review = DataQuality::Review.singleton_class
    review.alias_method :real_inbox_kind, :inbox_kind
    review.define_method(:inbox_kind) { |*, **| "new_record" }
    assert_equal "In your inbox", LeadFinding.state(lead.reload)
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
    claim.update!(status: "rejected")
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
end
