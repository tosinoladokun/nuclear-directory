require "test_helper"

# Suggest a company (#752): a name, website or link on Tosin's inbox; the
# finder runs in the background; the outcome shows on the inbox.
class Admin::SuggestCompanyTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  Found = Data.define(:outcome, :organization_id, :reason, :name, :website)

  setup do
    sign_in_as users(:admin)
    @finder = LeadFindJob.finder
  end

  teardown { LeadFindJob.finder = @finder }

  def suggest(text) = post(admin_inbox_suggest_path, params: { suggestion: text })

  test "Find queues the search and shows 'Finding it'; an empty or too long one is refused" do
    assert_enqueued_with(job: LeadFindJob) { suggest("  Kairos Power ") }
    lead = Lead.find_by!(normalized_name: "kairos power")
    assert_equal [ "company", "new", "Finding it", "human:tosin" ], lead.values_at(:kind, :status, :note, :decided_by)
    follow_redirect!
    assert_select "#suggestion-#{lead.id}", text: /Kairos Power.*Finding it/m

    assert_no_enqueued_jobs { suggest(" ") }
    assert_no_enqueued_jobs { suggest("x" * 501) }
  end

  test "a link is kept as the lead's source, named by its site" do
    suggest("https://www.linkedin.com/company/oklo-inc/")
    lead = Lead.find_by!(normalized_name: "linkedin com")
    assert_equal "https://www.linkedin.com/company/oklo-inc/", lead.sources.sole["url"]
  end

  test "outcomes: proposed leaves the list (it's a Create), listed already links the company, couldn't confirm says why" do
    known = Organization.create!(name: "Oklo", verification_status: "verified", verified_by: "human:tosin")
    results = {
      "New Fission" => Found.new(outcome: :proposed, organization_id: nil, reason: nil, name: "New Fission", website: "https://newfission.example"),
      "Oklo" => Found.new(outcome: :duplicate, organization_id: known.id, reason: nil, name: "Oklo", website: nil),
      "Bakery Co" => Found.new(outcome: :unconfirmed, organization_id: nil, reason: "no nuclear work on its site", name: "Bakery Co",
        website: "https://bakery.example")
    }
    LeadFindJob.finder = ->(lead) { results.fetch(lead.name) }
    perform_enqueued_jobs { results.each_key { |name| suggest(name) } }

    get admin_inbox_path
    assert_select "[id^=suggestion-]", text: /New Fission/, count: 0
    assert_select "[id^=suggestion-]", text: /Oklo.*Already listed/m
    assert_select "[id^=suggestion-] a[href=?]", admin_fact_path(type: "Organization", id: known.id)
    assert_select "[id^=suggestion-]", text: /Bakery Co.*Couldn't confirm: no nuclear work on its site: found Bakery Co, https:\/\/bakery.example/m
  end

  test "a finder that fails leaves 'couldn't confirm' and a retry next week, not 'finding' forever" do
    LeadFindJob.finder = ->(*) { raise Timeout::Error }
    suggest("Stuck Co")
    perform_enqueued_jobs
    lead = Lead.find_by!(normalized_name: "stuck co")
    assert_match "Couldn't confirm: the search stopped", lead.note
    assert_equal [ "researching", 1 ], lead.values_at(:status, :find_attempts)
    assert_in_delta 1.week.from_now, lead.next_find_at, 1.minute
  end
end
