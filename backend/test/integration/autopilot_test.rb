require "test_helper"

# The autopilot end to end (#811 part 1): a lead is found, its site checked, the company filled in (role, website,
# description, HQ) from its own pages, checked, and shown to Tosin as one Create row with all of it. Only the web
# and the models are stand-ins; every stage in between is the real one, so a break anywhere fails here.
class AutopilotTest < ActionDispatch::IntegrationTest
  HOME = "https://www.freshfission.example".freeze
  ABOUT = "#{HOME}/about".freeze
  # DQ's fixture (#811): the site names the company and its nuclear work, the About line states its role, a US address.
  PAGE = <<~HTML.freeze
    <html><head><title>Fresh Fission | Microreactors</title></head><body><nav><a href="/about">About us</a></nav>
    <h1>Fresh Fission</h1><p>Fresh Fission designs microreactors for remote sites.</p>
    <p>Fresh Fission Inc., 1 Main St, Austin, TX 78701</p></body></html>
  HTML
  ABOUT_PAGE = <<~HTML.freeze
    <html><body><p>Fresh Fission designs microreactors for remote sites.</p><p>Fresh Fission is a nuclear reactor developer building microreactors.</p><p>Headquartered in Austin, Texas.</p></body></html>
  HTML
  FOUND = {
    "description" => { "value" => "Fresh Fission designs microreactors for remote sites.", "quote" => "Fresh Fission designs microreactors for remote sites." },
    "hq_city" => { "value" => "Austin", "quote" => "Headquartered in Austin, Texas." },
    "hq_state" => { "value" => "Texas", "quote" => "Headquartered in Austin, Texas." },
    "roles" => [ { "key" => "reactor_vendor", "quote" => "Fresh Fission is a nuclear reactor developer" } ]
  }.freeze

  FakeLlm = Struct.new(:data) do
    def structured(**) = DataQuality::OpenRouter::Client::Response.new(data:, model: "fake", usage: {})
  end

  # The verifier: supported and sure, as the model says when the page states the claim.
  class Supported
    def call(candidate) = DataQuality::Verdict.new(outcome: :publish, confidence: 0.95, reason: "The page states it.")
  end

  setup do
    sign_in_as users(:admin)
    @finder = LeadFindJob.finder
    Role.find_by(key: "reactor_vendor") || Role.create!(key: "reactor_vendor", name: "Reactor developer")
    stub_request(:get, "#{HOME}/robots.txt").to_return(status: 404)
    stub_request(:get, "#{HOME}/sitemap.xml").to_return(status: 404)
    stub_request(:get, HOME).to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
    stub_request(:get, ABOUT).to_return(body: ABOUT_PAGE, headers: { "Content-Type" => "text/html" })
  end

  teardown { LeadFindJob.finder = @finder }

  def fetcher = DataQuality::Fetcher.new(sleeper: ->(_) { })

  test "lead -> find -> verify -> fill with its role -> check -> one Create row with role, website, description and HQ" do
    # 1. A lead with only a name, as a crawler or the Add a lead box leaves it.
    lead = Lead.sighted!(name: "Fresh Fission", kind: "company", key: "news:fresh-fission", label: "A press release")

    # 2. Find: the real finder and pipeline (extract, match); the search answers with the site.
    LeadFindJob.finder = lambda do |found|
      DataQuality::Plugins::LeadFinder.call(found.id, finder: DataQuality::Plugins::LeadFinder.new(fetcher:, search_key: nil, search: ->(_) { [ HOME ] }))
    end
    LeadFindJob.perform_now(lead.id)
    lead.reload
    assert_equal "added", lead.status, lead.note
    company = Organization.find_by!(name: "Fresh Fission")
    assert_equal [ "pending", HOME ], [ company.verification_status, company.website ]

    # 3. Verify the finder's claim.
    DataQuality::Pipeline.run("lead_finder", plugin: DataQuality::Plugins::LeadFinder.new(fetcher:, search_key: nil), only: %w[verify], verifier: Supported.new)
    assert_equal "recommend_publish", lead.candidate.reload.ai_recommendation

    # 4. Fill: the night's Enrich reads the new company's own pages (crawl, extract, match, verify).
    DataQuality::Pipeline.run("company_pages", plugin: DataQuality::Plugins::CompanyPages.new(fetcher:, llm: FakeLlm.new(FOUND)),
      only: %w[crawl extract match verify], verifier: Supported.new)
    assert Directory::Lookup.sourced_role?(company.id), "its role came from its own page"

    # 5. Check: Data Quality's approve on each open claim about it.
    roles = OrganizationRole.where(organization: company).select(:id)
    open = Candidate.where(status: DataQuality::Recommendations::OPEN)
      .and(Candidate.where(subject_type: "Organization", subject_id: company.id).or(Candidate.where(subject_type: "OrganizationRole", subject_id: roles)))
    assert open.exists?
    DataQuality::Recommendations.record(open.pluck(:id).map { |id| "#{id} approve: its own pages state it" }.join("\n"), by: "human:dq")
    assert_equal "In your inbox", LeadFinding.state(lead.reload)

    # 6. Tosin's Today: one Create row with everything on it.
    get admin_inbox_path
    assert_response :success
    row = css_select("[id^='inbox-'][id*='#{company.id}'], [id^='inbox-item-']").find { |node| node.text.include?("Fresh Fission") }
    assert row, "a Create row for Fresh Fission"
    text = row.text.squish
    assert_includes text, "Create"
    assert_match(/reactor developer/i, text, "role")
    assert_includes text, "freshfission.example", "website"
    assert_includes text, "Fresh Fission designs microreactors for remote sites.", "description"
    assert_match(/Austin/, text, "HQ city")
    assert_match(/TX/, text, "HQ state")
    assert_select "[id^='inbox-item-']", { text: /reactor developer/i, count: 1 }, "the role is on the Create row, not a row of its own"

    assert_match(/Role: Reactor developer/, text)

    # 7. Create: the company goes live with its role, website, description and HQ.
    form = row.css("form").find { |node| node.text.include?("Create") }
    params = form.css("input[type=hidden]").reject { |input| input["name"] == "authenticity_token" }
      .each_with_object(Hash.new { |h, k| h[k] = [] }) { |input, all| all[input["name"]] << input["value"] }
      .transform_values { |values| values.one? ? values.first : values }
    post form["action"], params: params.transform_keys { |name| name.delete_suffix("[]") }
    assert_nil flash[:alert]
    company.reload
    assert company.verified?
    assert_equal [ HOME, "Fresh Fission designs microreactors for remote sites.", "Austin", "TX" ],
      [ company.website, company.description, company.hq_city, company.hq_state ]
    assert OrganizationRole.where(organization: company, verification_status: "verified").joins(:role).exists?(roles: { key: "reactor_vendor" })
    assert_equal "Created", LeadFinding.state(lead.reload)
  end
end
