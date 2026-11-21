require "test_helper"

# #896: graders-approved spotlight drafts reach Admin > Posts without a console step, and are never sent from the endpoint.
class Api::SocialApprovedDraftsTest < ActionDispatch::IntegrationTest
  TOKEN = "approve-token"
  BY = "human:tosin"
  PAGE = Struct.new(:x) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: :ok, status: 200, body: "<p>Vistra generates electricity in Irving.</p>", etag: nil, last_modified: nil, reason: "x", block_reference: nil, content_type: "text/html", truncated: false) }
  TEXT = "Meet Vistra Corporation.\n\nBased in Irving, TX, Vistra generates and sells electricity and operates nuclear plants. Its releases record signed 20-year nuclear power agreements with AWS and Meta.".freeze

  setup do
    ENV["SOCIAL_APPROVE_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    SocialAgent::ApprovedDraft.fetcher = PAGE.new
    @company = Organization.create!(name: "Vistra Corporation", slug: "vistra-corporation", website: "https://vistracorp.com", domain: "vistracorp.com", verification_status: "verified", verified_by: BY,
      verified_at: 1.year.ago, description: "Power generation and retail electricity company.", hq_city: "Irving", hq_state: "TX")
    Evidence.create!(subject: @company, source: Source.create!(url: "https://vistracorp.com/about", source_kind: "web_page", crawl_status: "ok"), quote: "Power generation and retail electricity company. Irving, TX", found_by: "human")
    @link = "https://nuclear-directory.org/companies/vistra-corporation?utm_source=x&utm_medium=social&utm_campaign=vistra-corporation"
  end

  teardown do
    ENV.delete("SOCIAL_APPROVE_TOKEN_DIGEST")
    SocialAgent::ApprovedDraft.fetcher = nil
  end

  def approve(overrides = {}, token: TOKEN)
    params = { platform: "x", slug: "vistra-corporation", text: TEXT, link: @link, sha256: Digest::SHA256.hexdigest("#{TEXT}\n\n#{@link}"), graders: %w[GTM Founder DQ] }.merge(overrides)
    post api_social_approved_drafts_path, params:, headers: ({ "Authorization" => "Bearer #{token}" } if token), as: :json
  end

  test "no token configured: the endpoint doesn't exist; a wrong or missing token is refused" do
    ENV.delete("SOCIAL_APPROVE_TOKEN_DIGEST")
    approve
    assert_response :not_found
    ENV["SOCIAL_APPROVE_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    approve(token: "wrong")
    assert_response :unauthorized
    approve(token: nil)
    assert_response :unauthorized
    assert_equal 0, SocialPost.count
  end

  test "an approved text becomes a drafted post with the hash shown; nothing is sent; it appears in Admin > Posts with Send this draft" do
    SocialAgent.senders["x"] = ->(*) { flunk "the endpoint never sends" }
    assert_difference -> { SocialPost.count }, 1 do
      approve
    end
    assert_response :created
    body = response.parsed_body
    post = SocialPost.find(body["id"])
    assert_equal [ "drafted", "x", TEXT, @link, @company ], [ post.status, post.platform, post.text, post.link, post.subject ]
    assert_equal "approved by graders: GTM, Founder, DQ", post.reason
    assert_equal post.text_hash, body["text_hash"]
    assert body["warnings"].is_a?(Array)
    assert post.graded?
  ensure
    SocialAgent.senders.delete("x")
  end

  test "the text's own sha256 is also accepted (LinkedIn's text-only hash); a wrong hash is refused" do
    approve({ platform: "linkedin", link: @link.sub("utm_source=x", "utm_source=linkedin"), sha256: Digest::SHA256.hexdigest(TEXT) })
    assert_response :created
    SocialPost.delete_all
    approve({ sha256: Digest::SHA256.hexdigest("something else") })
    assert_response :unprocessable_entity
    assert_match(/sha256 matches neither/, response.parsed_body["errors"].join)
    assert_equal 0, SocialPost.count
  end

  test "refusals: not all three graders, an unknown company, a wrong link, a raw URL in the text, a hashtag, too long, a bad platform" do
    approve({ graders: %w[GTM DQ] })
    assert_match(/graders must name GTM, Founder and DQ/, response.parsed_body["errors"].join)
    approve({ slug: "nobody" })
    assert_match(/no published company/, response.parsed_body["errors"].join)
    approve({ link: "https://nuclear-directory.org/companies/vistra-corporation" })
    assert_match(/the link must be https:\/\/nuclear-directory.org\/companies\/vistra-corporation\?utm_source=x/, response.parsed_body["errors"].join)
    with_url = "#{TEXT} https://example.com/page"
    approve({ text: with_url, sha256: Digest::SHA256.hexdigest("#{with_url}\n\n#{@link}") })
    assert_match(/carries a URL/, response.parsed_body["errors"].join)
    tagged = "#{TEXT} #nuclear"
    approve({ text: tagged, sha256: Digest::SHA256.hexdigest("#{tagged}\n\n#{@link}") })
    assert_match(/hashtag/, response.parsed_body["errors"].join)
    long = "Meet Vistra Corporation. #{'It generates electricity in Irving. ' * 12}"
    approve({ text: long, sha256: Digest::SHA256.hexdigest("#{long}\n\n#{@link}") })
    assert_match(/too long/, response.parsed_body["errors"].join)
    approve({ platform: "mastodon" })
    assert_match(/platform must be x or linkedin/, response.parsed_body["errors"].join)
    assert_equal 0, SocialPost.count
  end

  test "one send per company and platform, and no second post inside the cooldown" do
    approve
    assert_response :created
    approve
    assert_response :unprocessable_entity
    assert_match(/already exists on this platform/, response.parsed_body["errors"].join)
    SocialPost.update_all(status: "posted")
    approve
    assert_match(/already sent a post about Vistra Corporation/, response.parsed_body["errors"].join)
    assert_equal 1, SocialPost.count
  end

  test "what the company page's words don't carry is a warning, not a refusal (hand-approved text, primary sources)" do
    approve
    assert_response :created
    assert response.parsed_body["warnings"].any? { |warning| warning.match?(/isn't in the source|which its source doesn't/) }, response.parsed_body["warnings"].inspect
  end

  test "Send this draft sends an approved draft exactly as stored after the guards, without the content recheck, and the DQ API says how it was approved" do
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 10, 0)
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    sent = []
    SocialAgent.senders["x"] = ->(text, link) { sent << [ text, link ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
    travel_to(monday) do
      approve
      post = SocialPost.last
      assert_equal "drafted", post.status
      result, why = SocialAgent.send_draft(post, now: monday)
      assert_nil why
      assert_equal [ [ TEXT, @link ] ], sent
      assert_equal "posted", post.reload.status
    end
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest("dq")
    get api_dq_social_posts_path, params: { since: "2026-11-20" }, headers: { "Authorization" => "Bearer dq" }
    assert_equal Api::Dq::SocialPostsController::GRADED, response.parsed_body["posts"].last["checks"]
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    SocialAgent.senders.delete("x")
  end
end
