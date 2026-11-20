require "test_helper"

# #811 alert -> fix: the Mac poller reads open (and just resolved) alerts with the session that fixes each.
class Api::AutopilotAlertsTest < ActionDispatch::IntegrationTest
  TOKEN = "alerts-token"

  setup { ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN) }
  teardown { ENV.delete("DQ_AGENT_TOKEN_DIGEST") }

  test "open and recently resolved alerts with their owner; nothing without the token" do
    AutopilotAlert.create!(key: "unchecked-claims", title: "152 company claims have no verdict yet", opened_at: 1.hour.ago)
    AutopilotAlert.create!(key: "queue-stuck", title: "The job queue is stuck", opened_at: 2.hours.ago, resolved_at: 1.hour.ago)
    AutopilotAlert.create!(key: "budget", title: "old", opened_at: 5.days.ago, resolved_at: 4.days.ago)
    get api_autopilot_alerts_path, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    alerts = response.parsed_body["alerts"].to_h { |alert| [ alert["key"], alert ] }
    assert_equal %w[queue-stuck unchecked-claims], alerts.keys.sort
    assert_equal [ "DQ", nil ], alerts["unchecked-claims"].values_at("owner", "resolved_at")
    assert_equal "Infra", alerts["queue-stuck"]["owner"]

    get api_autopilot_alerts_path
    assert_response :unauthorized
  end
end
