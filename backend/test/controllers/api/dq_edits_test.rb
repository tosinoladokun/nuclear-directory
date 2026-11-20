require "test_helper"

# #863 part 2: Data Quality fixes a news item's text through its endpoint.
class Api::DqEditsTest < ActionDispatch::IntegrationTest
  TOKEN = "edits-token"
  AUTH = { "Authorization" => "Bearer #{TOKEN}" }.freeze

  setup do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    @item = NewsItem.create!(url: "https://example.org/news/2", title: "Acme; Plant; Exemption", headline: "Acme gets an exemtpion",
      published_on: Date.new(2026, 11, 18), verification_status: "verified", verified_by: "human:tosin", verified_at: Time.current)
  end
  teardown { ENV.delete("DQ_AGENT_TOKEN_DIGEST") }

  def edit(**row) = post(api_dq_edits_path, params: { actions: [ { action: "edit_news", id: @item.id, **row } ] }, headers: AUTH, as: :json)

  test "edits the headline with a reason and source; the approver and status stay; listed and undoable" do
    edit(values: { headline: "Acme gets an exemption" }, reason: "Typo", source_url: "https://www.nrc.gov/x")
    assert_equal [ { "id" => @item.id, "ok" => true } ], response.parsed_body["results"]
    @item.reload
    assert_equal [ "Acme gets an exemption", "verified", "human:tosin" ], [ @item.headline, @item.verification_status, @item.verified_by ]
    event = @item.verification_events.order(:id).last
    assert_equal [ "agent:data-quality", "Typo", "https://www.nrc.gov/x" ], [ event.by, event.reason, event.context["source_url"] ]

    get api_dq_edits_path, headers: AUTH
    assert_equal [ @item.id, "https://www.nrc.gov/x" ], response.parsed_body["edits"].sole.values_at("id", "source_url")

    post api_dq_edits_undo_path, params: { id: @item.id }, headers: AUTH, as: :json
    assert response.parsed_body["ok"]
    assert_equal [ "Acme gets an exemtpion", "human:tosin" ], @item.reload.values_at(:headline, :verified_by)
  end

  test "edit only: a source, a reason and text fields are required; nothing else changes; a taken-off item isn't edited" do
    edit(values: { headline: "X" }, reason: "r")
    assert_match "source_url", response.parsed_body["results"].sole["error"]
    edit(values: { url: "https://evil.example" }, reason: "r", source_url: "https://a.example/")
    assert_match "can't edit", response.parsed_body["results"].sole["error"]
    post api_dq_edits_path, params: { actions: [ { action: "take_off", id: @item.id, reason: "r", source_url: "https://a.example/" } ] }, headers: AUTH, as: :json
    assert_match "action must be", response.parsed_body["results"].sole["error"]

    @item.unpublish!(by: "human:tosin")
    edit(values: { headline: "Y" }, reason: "r", source_url: "https://a.example/")
    assert_match "put it back", response.parsed_body["results"].sole["error"]
    assert_equal [ "Acme gets an exemtpion", "https://example.org/news/2" ], @item.reload.values_at(:headline, :url)
  end

  test "nothing without the token" do
    post api_dq_edits_path, params: { actions: [] }, as: :json
    assert_response :unauthorized
  end

  test "propose_takeoff puts one set of Yes/No rows in Today; Yes takes it off (reversible), No keeps it (#863)" do
    by = { verification_status: "verified", verified_by: "human:tosin", verified_at: Time.current }
    role = Role.first || Role.create!(key: "utility", name: "Utility")
    wrong = [ organizations(:westinghouse), organizations(:terrapower) ].map { |org| OrganizationRole.create!(organization: org, role:, **by) }
    post api_dq_edits_path, headers: AUTH, as: :json, params: { actions: wrong.map { |r| { action: "propose_takeoff", type: "OrganizationRole", id: r.id,
      reason: "Not a utility", source_url: "https://example.org/about", quote: "We design reactors." } } }
    results = response.parsed_body["results"]
    assert results.all? { |r| r["ok"] }
    assert_equal 1, results.map { |r| r["batch"] }.uniq.size, "one request is one set"
    assert_match "already proposed", (post(api_dq_edits_path, headers: AUTH, as: :json,
      params: { actions: [ { action: "propose_takeoff", type: "OrganizationRole", id: wrong.first.id, reason: "x", source_url: "https://a.example/" } ] }) && response.parsed_body["results"].sole["error"])

    sign_in_as users(:admin)
    get admin_inbox_path
    assert_select "section[aria-labelledby=inbox-takeoffs] li", 2
    proposal = TakeoffProposal.find_by!(subject_id: wrong.first.id)
    post admin_inbox_decide_takeoff_path(id: proposal.id, decision: "no")
    assert_equal [ "kept", "verified" ], [ proposal.reload.status, wrong.first.reload.verification_status ]

    post admin_inbox_decide_takeoff_set_path(batch: proposal.batch, decision: "yes")
    assert_equal "unpublished", wrong.last.reload.verification_status
    assert_equal "taken_off", TakeoffProposal.find_by!(subject_id: wrong.last.id).status
    assert_equal 2, OrganizationRole.where(id: wrong.map(&:id)).count, "never deleted"
  end

  test "at most PER_DAY edits and proposals a day (DQ)" do
    Api::Dq::EditsController::PER_DAY.times { |n| @item.verification_events.create!(from_status: "verified", to_status: "verified", by: "agent:data-quality", reason: "r#{n}") }
    edit(values: { headline: "Acme gets an exemption" }, reason: "Typo", source_url: "https://www.nrc.gov/x")
    assert_match "limit", response.parsed_body["results"].sole["error"]
    assert_equal "Acme gets an exemtpion", @item.reload.headline
  end
end
