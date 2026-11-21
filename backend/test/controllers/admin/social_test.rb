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

  test "a post made by hand is recorded per platform, so the agent won't post the item again (#877)" do
    news = NewsItem.create!(url: "https://nanonuclearenergy.com/mou", title: "NANO and SJ Group sign a non-binding MOU", publisher: "NANO Nuclear Energy", published_on: Date.new(2026, 11, 19),
      verification_status: "verified", verified_by: "human:tosin", verified_at: 1.day.ago)
    company = Organization.create!(name: "NANO Nuclear Energy", slug: "nano-nuclear-energy", verification_status: "verified", verified_by: "human:tosin")
    news.news_mentions.create!(subject: company)

    assert_difference -> { SocialPost.count }, 2 do
      post admin_social_by_hand_path, params: { item: news.id.to_s, platforms: %w[x linkedin], permalink: "https://x.com/NuclearDir/status/1" }
    end
    assert_redirected_to admin_social_path
    rows = SocialPost.where(subject: news).order(:platform)
    assert_equal %w[linkedin x], rows.map(&:platform)
    assert rows.all? { |row| row.status == "posted" && row.organization_ids == [ company.id ] && row.permalink == "https://x.com/NuclearDir/status/1" }
    assert SocialPost.used.exists?(subject: news), "counts as used: the picker's cooldown sees it"

    assert_no_difference -> { SocialPost.count } do
      post admin_social_by_hand_path, params: { item: news.url, platforms: %w[x] }
    end
    assert_match(/already had it/, flash[:notice], "the one-send index: a second record is a no-op")

    assert_no_difference -> { SocialPost.count } do
      post admin_social_by_hand_path, params: { item: "999999", platforms: %w[x] }
      post admin_social_by_hand_path, params: { item: news.id.to_s, platforms: [] }
      post admin_social_by_hand_path, params: { item: news.id.to_s, platforms: %w[x], permalink: "javascript:alert(1)" }
    end
    assert_match(/Not recorded/, flash[:alert])

    get admin_social_path
    assert_select "form#social-by-hand-form input[name='platforms[]']", 2
    assert_select ".nd-wait__what", text: /Posted by hand/
  end

  test "the news item can be given by its admin address, and an automated post still queued must be taken back first (Copilot, #878)" do
    news = NewsItem.create!(url: "https://nanonuclearenergy.com/mou2", title: "NANO and SJ Group sign a non-binding MOU", publisher: "NANO Nuclear Energy", published_on: Date.new(2026, 11, 19),
      verification_status: "verified", verified_by: "human:tosin", verified_at: 1.day.ago)

    assert_difference -> { SocialPost.count }, 1 do
      post admin_social_by_hand_path, params: { item: "https://www.nuclear-directory.org/admin/facts/NewsItem/#{news.id}", platforms: %w[x] }
    end
    assert SocialPost.find_by(platform: "x", subject: news).by_hand?, "its reason says it was posted by hand"
    assert_no_difference -> { SocialPost.count } do
      post admin_social_by_hand_path, params: { item: "/admin/facts/NewsItem/#{news.id}", platforms: %w[x] }
    end
    assert_match(/already had it/, flash[:notice])

    queued = NewsItem.create!(url: "https://nanonuclearenergy.com/mou3", title: "Another item", publisher: "NANO Nuclear Energy", published_on: Date.new(2026, 11, 19),
      verification_status: "verified", verified_by: "human:tosin", verified_at: 1.day.ago)
    SocialPost.create!(platform: "linkedin", status: "queued", subject: queued, text: "Automated.", external_id: "b1", posted_at: 1.hour.from_now)
    assert_no_difference -> { SocialPost.count } do
      post admin_social_by_hand_path, params: { item: queued.id.to_s, platforms: %w[linkedin x] }
    end
    assert_match(/LinkedIn has an automated post queued in Buffer/, flash[:alert])
    assert_equal 0, SocialPost.where(subject: queued, status: "posted").count, "nothing recorded for either platform until it is taken back"

    get admin_social_path
    assert_select ".nd-wait__what .text-critical", text: SocialPost::BY_HAND, count: 0
  end

  test "hostless links record nothing, and an unknown post is settled by hand so recording can go on (Copilot, #878)" do
    news = NewsItem.create!(url: "https://nanonuclearenergy.com/mou9", title: "Item", publisher: "NANO", published_on: Date.new(2026, 11, 19),
      verification_status: "verified", verified_by: "human:tosin", verified_at: 1.day.ago)
    [ "https://?", "https:///status/1" ].each do |bad|
      assert_no_difference -> { SocialPost.count } do
        post admin_social_by_hand_path, params: { item: news.id.to_s, platforms: %w[x], permalink: bad }
      end
      assert_match(/Not recorded/, flash[:alert])
    end
    unknown = SocialPost.create!(platform: "x", status: "unknown", subject: news, text: "Auto.", posted_at: 1.hour.ago)
    post admin_social_by_hand_path, params: { item: news.id.to_s, platforms: %w[x] }
    assert_match(/marked unknown/, flash[:alert])
    post admin_social_reconcile_path(unknown, outcome: "never")
    assert_equal "cancelled", unknown.reload.status
    assert_difference -> { SocialPost.where(status: "posted").count }, 1 do
      post admin_social_by_hand_path, params: { item: news.id.to_s, platforms: %w[x] }
    end
  end

  test "reconcile takes only sent or never, and only while the post is still unknown (#878)" do
    news = NewsItem.create!(url: "https://nanonuclearenergy.com/mou10", title: "Item", publisher: "NANO", published_on: Date.new(2026, 11, 19),
      verification_status: "verified", verified_by: "human:tosin", verified_at: 1.day.ago)
    unknown = SocialPost.create!(platform: "x", status: "unknown", subject: news, text: "Auto.", posted_at: 1.hour.ago)
    [ "", "maybe", "Never " ].each do |outcome|
      post admin_social_reconcile_path(unknown, outcome:)
      assert_match(/Say whether it went out/, flash[:alert])
      assert_equal "unknown", unknown.reload.status, "an unclear answer never frees the item for a resend"
    end
    post admin_social_reconcile_path(unknown)
    assert_equal "unknown", unknown.reload.status
    unknown.update_columns(status: "posted")
    post admin_social_reconcile_path(unknown, outcome: "never")
    assert_match(/Only a post marked unknown/, flash[:alert])
    assert_equal "posted", unknown.reload.status, "a post settled meanwhile isn't changed"
    unknown.update_columns(status: "unknown")
    post admin_social_reconcile_path(unknown, outcome: "sent", permalink: "https://x.com/NuclearDir/status/5")
    assert_equal [ "posted", "https://x.com/NuclearDir/status/5" ], unknown.reload.values_at(:status, :permalink)
  end
end
