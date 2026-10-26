require "test_helper"

# #548 option a: Data Quality's agent settles company claims through a
# token-only API; nothing it does publishes, and each action can be undone.
class Api::DqMatchingTest < ActionDispatch::IntegrationTest
  TOKEN = "dq-test-token".freeze

  setup do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    @holtec = Organization.create!(name: "Holtec International", verification_status: "verified", verified_by: "human:tosin")
    @holtec.aliases.create!(alias: "Holtec International")
    @page = Source.create!(url: "https://www.nrc.gov/test/dq.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: "Licensee: Holtec. Licensee: Fresh Fission LLC. Licensee: Child Fission.")
  end

  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  def claim(name, quote: "Licensee: #{name}.", **payload) = Candidate.create!(source: @page, kind: "organization", status: "needs_review",
    payload: { "name" => name, **payload }, quote:, notes: %(no exact match for "#{name}"))
  def act(*rows, token: TOKEN) = post(api_dq_matching_path, params: { actions: rows }, as: :json, headers: { "Authorization" => "Bearer #{token}" })
  def results = response.parsed_body["results"]

  test "no token configured, or a malformed digest: the endpoint doesn't exist" do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    act({ id: 1, action: "close", reason: "x" })
    assert_response :not_found
    ENV["DQ_AGENT_TOKEN_DIGEST"] = "not-a-digest"
    act({ id: 1, action: "close", reason: "x" })
    assert_response :not_found
  end

  test "a wrong, missing or cookie-only request is refused, without echoing anything" do
    act({ id: 1, action: "close", reason: "x" }, token: "wrong")
    assert_response :unauthorized
    assert_equal({ "error" => "unauthorized" }, response.parsed_body)
    assert_not_includes response.body, ENV["DQ_AGENT_TOKEN_DIGEST"]
    post api_dq_matching_path, params: { actions: [] }, as: :json
    assert_response :unauthorized
    sign_in_as users(:admin)
    post api_dq_matching_path, params: { actions: [] }, as: :json
    assert_response :unauthorized, "an admin's session cookie is never enough"
  end

  test "the rate limit trips before auth, so guessing isn't free" do
    61.times { act({ id: 1, action: "close", reason: "x" }, token: "wrong") }
    assert_response :too_many_requests
  ensure
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  test "the token never appears in the log" do
    log = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    act({ id: claim("Holtec").id, action: "close", reason: "r" })
    assert_not_includes log.string, TOKEN
  ensure
    Rails.logger = old
  end

  test "a daily cap on new companies, and batches of at most 50" do
    DataQuality::Matching::DAILY_CREATES.times { |i| DqAction.create!(candidate: claim("Cap #{i}"), action: "new", reason: "r", before: {}, by: DataQuality::Matching::BY) }
    act({ id: claim("Fresh Fission LLC").id, action: "new", reason: "r" })
    assert_match "today's limit", results.sole["error"]
    act(*51.times.map { { id: 1, action: "close", reason: "r" } })
    assert_response :unprocessable_content
  end

  test "same_as: a name variant confirms with its source, publishing nothing new; sent again it's a no-op" do
    variant = claim("Holtec")
    act({ id: variant.id, action: "same_as", target: @holtec.slug, reason: "Same company, short name" })
    assert_equal [ true ], results.map { |r| r["ok"] }, results.inspect
    assert_equal [ "confirmed", @holtec.id ], variant.reload.values_at(:status, :subject_id)
    assert Evidence.exists?(subject: @holtec, quote: "Licensee: Holtec.")
    assert_equal [ "Holtec International" ], @holtec.aliases.pluck(:alias), "no alias without add_alias"
    assert_equal DataQuality::Matching::BY, DqAction.sole.by

    act({ id: variant.id, action: "same_as", target: @holtec.id, reason: "again" })
    assert results.sole["ok"]
    assert_equal 1, DqAction.count
  end

  test "same_as with add_alias stays matched, so the new name is a Change for Tosin" do
    variant = claim("Holtec")
    act({ id: variant.id, action: "same_as", target: @holtec.id, reason: "Keep the short name", add_alias: true })
    assert_equal "matched", variant.reload.status
    assert_equal "change", DataQuality::Review.inbox_kind(variant)
  end

  test "a target is an id or slug, never a name; unknown or missing is an error, and the claim is left as it was" do
    c = claim("Holtec")
    act({ id: c.id, action: "same_as", target: "Holtec International", reason: "r" }, { id: c.id, action: "same_as", reason: "r" })
    assert_match "no open company", results.first["error"]
    assert_match "give the company", results.second["error"]
    assert_equal "needs_review", c.reload.status
  end

  test "new: a pending company for Tosin's Create; Undo takes it back" do
    c = claim("Fresh Fission LLC")
    act({ id: c.id, action: "new", reason: "A new licensee" })
    company = Organization.find(results.sole["created_ids"].sole)
    assert company.verification_status == "pending"
    assert_equal "new_record", DataQuality::Review.inbox_kind(c.reload)

    post api_dq_matching_undo_path, params: { action_id: DqAction.sole.id }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert response.parsed_body["ok"], response.parsed_body.inspect
    assert_equal [ "needs_review", nil ], c.reload.values_at(:status, :subject_id)
    assert_equal "rejected", company.reload.verification_status
  end

  test "subsidiary_of: a pending company and a pending link naming the parent" do
    c = claim("Child Fission")
    act({ id: c.id, action: "subsidiary_of", target: @holtec.id, reason: "Holtec's unit" })
    assert results.sole["ok"], results.inspect
    link = Relationship.find_by!(relationship_type: "subsidiary_of", to_organization: @holtec)
    assert_equal "pending", link.verification_status
    link_claim = Candidate.find_by!(subject_type: "Relationship", subject_id: link.id)
    assert_equal "Holtec International", link_claim.payload.dig("to_organization", "name")
    assert_equal "new_fact", DataQuality::Review.inbox_kind(link_claim)
  end

  test "close: rejected with the reason; a lead's name stays in Leads" do
    lead = claim("Maybe Fission", lead: true)
    act({ id: lead.id, action: "close", reason: "Trade press only" })
    assert_equal "rejected", lead.reload.status
    assert_match "Trade press only", lead.notes
    assert Lead.exists?(normalized_name: "maybe fission")
  end

  test "a claim already attached or decided is refused" do
    c = claim("Holtec")
    c.update!(status: "matched", subject_type: "Organization", subject_id: @holtec.id)
    act({ id: c.id, action: "close", reason: "r" })
    assert results.sole["ok"], "skipped, not an error"
    assert_match "skipped: it's already attached or decided", results.sole["error"]
    assert_equal 0, DqAction.count
  end

  test "a retried request with the same key applies once; the new company's history says Data Quality proposed it" do
    c = claim("Fresh Fission LLC")
    2.times { act({ id: c.id, action: "new", reason: "A new licensee", request_key: "batch-1-row-1" }) }
    assert_equal 1, DqAction.count
    company = Organization.find(results.sole["created_ids"].sole)
    event = DataQuality::DirectoryClient.new.verification_history(type: "Organization", id: company.id).last
    assert_equal DataQuality::Matching::BY, event.by
  end

  test "Undo refuses once another claim is attached to what it created" do
    c = claim("Fresh Fission LLC")
    act({ id: c.id, action: "new", reason: "A new licensee" })
    company_id = results.sole["created_ids"].sole
    claim("Fresh Fission LLC").update!(status: "matched", subject_type: "Organization", subject_id: company_id)
    assert_match "claimed since", DataQuality::Matching.undo(DqAction.sole.id)
    assert_nil DqAction.sole.undone_at
  end
end
