require "test_helper"

# #776: Data Quality reads the checker's shadow verdicts with its token.
class Api::DqCheckerTest < ActionDispatch::IntegrationTest
  TOKEN = "checker-token"

  setup { ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN) }
  teardown { ENV.delete("DQ_AGENT_TOKEN_DIGEST") }

  test "counts by field and verdict and each verdict since a day; nothing without the token" do
    source = Source.create!(url: "https://a.example/", source_kind: "dummy", crawl_status: "ok", content_sha256: "s")
    claim = Candidate.create!(source:, kind: "organization", payload: { "name" => "A" }, quote: "q")
    CheckerVerdict.create!(candidate: claim, field: "website", verdict: "unsure", reason: "thin page", prompt_version: "checker-v1")
    get api_dq_checker_path, params: { since: Date.current.iso8601 }, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    assert_equal({ "website" => { "unsure" => 1 } }, response.parsed_body["counts"])
    assert_equal [ claim.id, "unsure", "thin page" ], response.parsed_body["verdicts"].sole.values_at("candidate_id", "verdict", "reason")

    get api_dq_checker_path
    assert_response :unauthorized
  end
end
