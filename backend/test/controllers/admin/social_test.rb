require "test_helper"

# The social agent's admin page (#769): switches and the log.
class Admin::SocialTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:admin) }

  test "each platform starts off; the switch changes its mode; the log shows each post with its source" do
    company = Organization.create!(name: "Acme Fission", verification_status: "verified", verified_by: "human:tosin")
    SocialPost.create!(platform: "x", status: "posted", subject: company, text: "Acme Fission won a DOE award.",
      permalink: "https://x.com/NuclearDir/status/1", source_url: "https://example.com/acme-award")
    get admin_social_path
    assert_select "#social-switch-x button[aria-pressed=true]", "Off"
    assert_select "#social-switch-linkedin button[aria-pressed=true]", "Off"
    assert_select "li[id^=social-post] a[href=?]", "https://x.com/NuclearDir/status/1"
    assert_select "li[id^=social-post] a", /Source: example\.com/

    patch admin_social_channel_path("x"), params: { mode: "drafts" }
    assert_equal "drafts", SocialChannel.for("x").mode
    patch admin_social_channel_path("x"), params: { mode: "loud" }
    assert_match "Not changed", flash[:alert]
  end

  test "a platform the agent switched off itself is said in Today, and setting it again clears that" do
    SocialChannel.for("x").update!(mode: "off", paused_reason: "2 sends in a row didn't go through")
    get admin_inbox_path
    assert_select "#social-paused-x", /Posting to X stopped: 2 sends in a row didn't go through/
    patch admin_social_channel_path("x"), params: { mode: "drafts" }
    assert_nil SocialChannel.for("x").paused_reason
  end

  test "Draft now queues today's drafts, never a send (PM)" do
    get admin_social_path
    assert_select "form#social-draft-now button", "Draft now"
    SocialChannel.for("x").update!(mode: "drafts")
    travel_to Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 9, 0) do
      assert_enqueued_with(job: SocialPostJob, args: [ { drafts_only: true } ]) { post admin_social_draft_now_path }
      assert_redirected_to admin_social_path
      assert_equal "Drafting now. Reload in a minute to see it in the log. Not drafting: LinkedIn: switched off.", flash[:notice]
    end

    # A weekend says so, and nothing is queued (DQ).
    travel_to Time.find_zone(SocialAgent::ZONE).local(2026, 11, 21, 9, 0) do
      assert_no_enqueued_jobs(only: SocialPostJob) { post admin_social_draft_now_path }
      assert_equal "No draft. Why: X: it's a weekend; LinkedIn: switched off.", flash[:notice]
    end
  end
end
