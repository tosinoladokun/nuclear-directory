require "test_helper"

# #811: the Health page and Data Quality's endpoint.
class Admin::HealthTest < ActionDispatch::IntegrationTest
  TOKEN = "health-token"

  setup do
    sign_in_as users(:admin)
    Organization.create!(name: "No Role Co", verification_status: "pending", created_at: 2.days.ago)
  end

  test "the page lists the problems and the counts" do
    get admin_health_path
    assert_select "#health-list li", /pending companies have had no role/
    assert_select "#health-pending-without-role", PipelineHealth.new.counts["pending_without_role"].to_s
  end

  test "Data Quality's endpoint returns the same, with the token" do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    get api_dq_health_path, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    assert_equal PipelineHealth.new.counts["pending_without_role"], response.parsed_body.dig("counts", "pending_without_role")
    assert(response.parsed_body["problems"].any? { |problem| problem.include?("no role") })
  ensure
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
  end
end
