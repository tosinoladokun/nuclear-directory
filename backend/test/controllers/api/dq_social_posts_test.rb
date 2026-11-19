require "test_helper"

# #769 shadow: Data Quality reads the social agent's drafts with its token.
class Api::DqSocialPostsTest < ActionDispatch::IntegrationTest
  TOKEN = "social-token"

  setup { ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN) }
  teardown { ENV.delete("DQ_AGENT_TOKEN_DIGEST") }

  test "drafts and stopped posts since a day, with why and the source; nothing without the token" do
    company = Organization.create!(name: "Acme Fission", verification_status: "verified", verified_by: "human:tosin")
    SocialPost.create!(platform: "x", status: "drafted", subject: company, text: "Acme Fission won a DOE award.", source_url: "https://www.energy.gov/a")
    SocialPost.create!(platform: "x", status: "blocked", subject: company, text: "Old.", reason: "stale", created_at: 10.days.ago)
    get api_dq_social_posts_path, params: { since: 2.days.ago.to_date.iso8601 }, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    post = response.parsed_body["posts"].sole
    assert_equal [ "x", "drafted", "Acme Fission won a DOE award.", "https://www.energy.gov/a" ], post.values_at("platform", "status", "text", "source_url")
    assert_equal Api::Dq::SocialPostsController::PASSED, post["checks"], "a draft passed every check"

    get api_dq_social_posts_path
    assert_response :unauthorized
  end
end
