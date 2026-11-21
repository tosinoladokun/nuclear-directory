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

  test "a post recorded by hand is reported as manually recorded, never as having passed the automated checks (Copilot, #878)" do
    company = Organization.create!(name: "Acme Fission", verification_status: "verified", verified_by: "human:tosin")
    SocialPost.create!(platform: "x", status: "posted", subject: company, text: "Posted by hand.", reason: SocialPost::BY_HAND, permalink: "https://x.com/NuclearDir/status/1")
    get api_dq_social_posts_path, params: { since: 2.days.ago.to_date.iso8601 }, headers: { "Authorization" => "Bearer #{TOKEN}" }
    post = response.parsed_body["posts"].sole
    assert_equal true, post["by_hand"]
    assert_equal Api::Dq::SocialPostsController::MANUAL, post["checks"]
    assert_not_equal Api::Dq::SocialPostsController::PASSED, post["checks"]
  end

  test "a run that wrote no post is listed with why: switched off, or nothing fresh (PM: never silence)" do
    SocialChannel.for("x").update!(mode: "off")
    SocialChannel.for("linkedin").update!(mode: "drafts")
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)
    travel_to(monday) do
      assert_nil SocialAgent.run("x")
    end
    get api_dq_social_posts_path, params: { since: "2026-11-23" }, headers: { "Authorization" => "Bearer #{TOKEN}" }
    runs = response.parsed_body["runs"]
    assert_includes runs.map { |run| run.values_at("platform", "stopped") }, [ "x", "switched off in Admin > Posts" ]
  end
end
