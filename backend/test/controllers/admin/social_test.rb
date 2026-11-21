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

  MONDAY = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 10, 0)

  def draft_for(platform: "x", news: nil, at: MONDAY - 1.hour)
    news ||= NewsItem.create!(url: "https://www.energy.gov/a#{SecureRandom.hex(3)}", title: "Acme Fission wins a DOE award", publisher: "DOE", published_on: Date.new(2026, 11, 20),
      verification_status: "verified", verified_by: "human:tosin", verified_at: MONDAY - 3.days)
    SocialPost.create!(platform:, status: "drafted", subject: news, text: "DOE said on 20 November it awarded Acme Fission a grant.", link: "https://nuclear-directory.org/companies/acme",
      source_url: news.url, organization_ids: [], created_at: at)
  end

  test "Send this draft sends that exact draft through the platform's sender, once, after every guard (#879)" do
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    draft = draft_for
    sent = []
    SocialAgent.senders["x"] = ->(text, link) { sent << [ text, link ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
    travel_to(MONDAY) do
      get admin_social_path
      assert_select "form#social-send-#{draft.id} button, form#social-send-#{draft.id} input[type=submit]", 1
      post admin_social_send_draft_path(draft)
      assert_match(/Sent to X/, flash[:notice])
      assert_equal [ [ draft.text, draft.link ] ], sent, "the exact text and link"
      assert_equal [ "posted", "https://x.com/i/web/status/9" ], draft.reload.values_at(:status, :permalink)

      post admin_social_send_draft_path(draft)
      assert_match(/only a draft that passed every check can be sent \(this one is posted\)/, flash[:alert])
      assert_equal 1, sent.size, "a second click can't send it again"
    end
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end

  test "Send this draft refuses with its reason: server off, platform off, weekend, an old draft, today's slot, the cooldown, a blocked row (#879)" do
    SocialAgent.senders["x"] = ->(*) { flunk "never sent" }
    SocialChannel.for("x").update!(mode: "drafts")
    draft = draft_for
    refuse = ->(pattern, at: MONDAY) do
      travel_to(at) { post admin_social_send_draft_path(draft) }
      assert_match pattern, flash[:alert]
      assert_equal "drafted", draft.reload.status, "nothing was sent"
    end

    refuse.(/sending is off on the server/)
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "off")
    refuse.(/X is switched off/)
    SocialChannel.for("x").update!(mode: "drafts")
    refuse.(/it's a weekend/, at: MONDAY + 5.days)
    refuse.(/this draft is from 23 Nov: draft again today/, at: MONDAY + 1.day)

    other = draft_for(news: nil)
    other.update_columns(status: "posted")
    refuse.(/today's post for this platform is already out/)
    other.destroy

    SocialPost.create!(platform: "linkedin", status: "posted", subject: draft.subject, text: "Earlier.", created_at: MONDAY - 3.days)
    refuse.(/the same item was posted within the last 14 days/)

    draft.update_columns(status: "blocked")
    refuse_blocked = -> { travel_to(MONDAY) { post admin_social_send_draft_path(draft) } }
    refuse_blocked.()
    assert_match(/only a draft that passed every check can be sent \(this one is blocked\)/, flash[:alert])
    get admin_social_path
    assert_select "form#social-send-#{draft.id}", 0, "a blocked row has no Send button"
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end

  test "Send this draft keeps the monthly caps: over the month's cap it blocks, with the cap's reason, and sends nothing (#879)" do
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    SocialAgent.senders["x"] = ->(*) { flunk "never sent over the cap" }
    original = ENV["SOCIAL_MONTHLY_MAX"]
    ENV["SOCIAL_MONTHLY_MAX"] = "1"
    SocialPost.create!(platform: "x", status: "posted", subject: NewsItem.create!(url: "https://www.energy.gov/old", title: "Old", publisher: "DOE", published_on: Date.new(2026, 11, 2),
      verification_status: "verified", verified_by: "human:tosin", verified_at: MONDAY - 20.days), text: "Old.", created_at: MONDAY - 10.days)
    draft = draft_for
    travel_to(MONDAY) { post admin_social_send_draft_path(draft) }
    assert_match(/Not sent to X: this month's 1 posts are done/, flash[:alert])
    assert_equal "blocked", draft.reload.status
  ensure
    ENV["SOCIAL_MONTHLY_MAX"] = original
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end
end
