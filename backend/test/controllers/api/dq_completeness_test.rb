require "test_helper"

class Api::DqCompletenessTest < ActionDispatch::IntegrationTest
  TOKEN = "dq-test-token".freeze

  setup { ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN) }
  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    Api::DqAgent::RATE_LIMIT_STORE.clear
  end

  test "token only; the count as JSON and the worklist as CSV" do
    Organization.create!(name: "Bare Co", verification_status: "verified", verified_by: "human:tosin")
      .evidence.create!(source: sources(:press_release), quote: "Bare Co.", found_by: "human", confidence: 1)

    get api_dq_completeness_path
    assert_response :unauthorized

    get api_dq_completeness_path, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    body = response.parsed_body
    assert_equal 0, body["complete"]
    assert_includes body["companies"].map { |row| row["name"] }, "Bare Co"

    get api_dq_completeness_path(format: :csv), headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    assert_includes response.body, "bare-co,Bare Co,yes,yes,yes,yes"
  end
end
