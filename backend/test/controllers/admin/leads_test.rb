require "test_helper"

class Admin::LeadsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:admin)
    @often = Lead.sighted!(name: "Often Seen Fission", kind: "company", key: "a", label: "Search with no results", times: 9)
    @once = Lead.sighted!(name: "Once Seen Co", kind: "company", key: "b", label: "News: a headline", url: "https://example.com/n")
  end

  test "the list shows most-seen first with where each came from; the nav counts new leads" do
    get admin_leads_path
    assert_response :success
    assert_select "ol.nd-waits > li", 2
    assert_select "ol.nd-waits > li:first-child .type-subject", "Often Seen Fission"
    assert_select "#lead-#{@once.id} a[href='https://example.com/n']", "News: a headline"
    assert_select "nav a", /Leads\s*2/
  end

  test "Research reads a company we have, starting Enrich; otherwise it marks the lead for Data Quality" do
    company = Organization.create!(name: "Often Seen Fission", website: "https://often.example.com/", verification_status: "verified", verified_by: "human:tosin")
    assert_enqueued_with(job: DataQuality::RunJob) { post research_admin_lead_path(@often) }
    assert_redirected_to admin_record_enrich_path(type: "Organization", id: company.id)
    assert_equal [ "researching", "Organization", company.id ], @often.reload.values_at(:status, :record_type, :record_id)
    assert company.reload.enrich_requested_at

    post research_admin_lead_path(@once)
    assert_redirected_to admin_leads_path
    assert @once.reload.status_researching?
  end

  test "Already covered links the record by name; an unknown name is refused; Ignore needs a reason; Back to new reopens" do
    company = Organization.create!(name: "Once Seen Company", verification_status: "verified", verified_by: "human:tosin")
    company.aliases.create!(alias: "Once Seen Company")
    post covered_admin_lead_path(@once), params: { record: "Nobody At All" }
    assert_match "No company or plant is called", flash[:alert]
    post covered_admin_lead_path(@once), params: { record: "Once Seen Company" }
    assert_equal [ "added", company.id ], @once.reload.values_at(:status, :record_id)

    post ignore_admin_lead_path(@often), params: { reason: "" }
    assert_match "Say why", flash[:alert]
    post ignore_admin_lead_path(@often), params: { reason: "Not nuclear" }
    assert_equal [ "ignored", "Not nuclear" ], @often.reload.values_at(:status, :reason)
    post reopen_admin_lead_path(@often, tab: "ignored")
    assert @often.reload.status_new?
  end

  test "a pasted list adds one lead per line, with its note" do
    post admin_leads_path, params: { kind: "company", names: "Pasted Fusion: from DOE GAIN\n\nOther Pasted Co\n" }
    assert_equal "Added 2 leads.", flash[:notice]
    assert_equal "from DOE GAIN", Lead.find_by!(name: "Pasted Fusion").note
  end
end
