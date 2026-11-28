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

  test "Data Quality's pass: off shows one Turn on button with a confirmation; on shows one Turn off button, Pacific times (#998, Design)" do
    get admin_health_path
    assert_select "#health-dq-pass-state", /\AOff\.\z/
    assert_select "section[aria-labelledby=health-dq-pass] p", text: /Each night at \d{1,2}:30 [ap]\.m\. Pacific/
    assert_select "#dq-pass-on button.nd-btn--primary[data-turbo-confirm]", "Turn on"
    assert_select "#dq-pass-off", false
    assert_select "section[aria-labelledby=health-dq-pass] [aria-pressed]", false

    patch admin_health_dq_pass_path, params: { on: "1" }
    assert_redirected_to admin_health_path
    assert_match(/runs each night at \d{1,2}:30 [ap]\.m\. Pacific/, flash[:notice])
    assert DqPass.on?
    assert_equal users(:admin).actor, Switch.find_by!(key: DqPass::KEY).changed_by

    get admin_health_path
    assert_select "#health-dq-pass-state", /\AOn, since \d{1,2} \w{3} \d\d:\d\d PT\. First run tonight\./
    assert_select "#dq-pass-off button.nd-btn--outline:not([data-turbo-confirm])", "Turn off"
    assert_select "#dq-pass-on", false

    patch admin_health_dq_pass_path, params: { on: "0" }
    assert_not DqPass.on?
  end

  test "the nightly time reads in Pacific: 2:30 a.m. in winter, 3:30 a.m. in summer (#998, Design)" do
    assert_equal "2:30 a.m.", DqPass.run_time_pacific(now: Time.utc(2026, 12, 2, 12))
    assert_equal "3:30 a.m.", DqPass.run_time_pacific(now: Time.utc(2027, 7, 2, 12))
  end

  test "the switch needs a signed-in admin (#998)" do
    sign_out
    patch admin_health_dq_pass_path, params: { on: "1" }
    assert_not DqPass.on?
  end

  test "the admin layout turns off Turbo's hover prefetch, so a mouse across the nav fetches nothing (#1026)" do
    get admin_health_path
    assert_select "head meta[name='turbo-prefetch'][content='false']", 1
  end
end
