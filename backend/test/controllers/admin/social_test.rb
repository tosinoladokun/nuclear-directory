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
end
