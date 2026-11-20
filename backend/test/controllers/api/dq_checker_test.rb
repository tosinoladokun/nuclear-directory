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

    assert_nil response.parsed_body["next_after"]

    stub_const = Api::Dq::CheckerController::MAX
    2.times { CheckerVerdict.create!(candidate: claim, field: "website", verdict: "approve", reason: "r", prompt_version: "v#{_1}") }
    Api::Dq::CheckerController.send(:remove_const, :MAX)
    Api::Dq::CheckerController.const_set(:MAX, 2)
    get api_dq_checker_path, params: { since: Date.current.iso8601 }, headers: { "Authorization" => "Bearer #{TOKEN}" }
    first = response.parsed_body
    assert_equal 2, first["verdicts"].size
    get api_dq_checker_path, params: { since: Date.current.iso8601, after: first["next_after"] }, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_equal 1, response.parsed_body["verdicts"].size, "the rest on the next page"
    assert_nil response.parsed_body["next_after"]
    assert_equal 3, response.parsed_body["counts"]["website"].values.sum

    get api_dq_checker_path
    assert_response :unauthorized
  ensure
    Api::Dq::CheckerController.send(:remove_const, :MAX)
    Api::Dq::CheckerController.const_set(:MAX, stub_const || 500)
  end
end
