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
    SocialAgent.draft_fetcher = PAGE.new
    Api::SocialApproval::RATE_LIMIT_STORE.clear
    @company = Organization.create!(name: "Vistra Corporation", slug: "vistra-corporation", website: "https://vistracorp.com", domain: "vistracorp.com", verification_status: "verified", verified_by: BY,
      verified_at: 1.year.ago, description: "Power generation and retail electricity company.", hq_city: "Irving", hq_state: "TX")
    Evidence.create!(subject: @company, source: Source.create!(url: "https://vistracorp.com/about", source_kind: "web_page", crawl_status: "ok"), quote: "Power generation and retail electricity company. Irving, TX", found_by: "human")
    @link = "https://nuclear-directory.org/companies/vistra-corporation?utm_source=x&utm_medium=social&utm_campaign=vistra-corporation"
  end

  teardown do
    ENV.delete("SOCIAL_APPROVE_TOKEN_DIGEST")
    SocialAgent::ApprovedDraft.fetcher = nil
    SocialAgent.draft_fetcher = nil
  end

  # dq: false = Data Quality has not recorded its PASS for this hash.
  def approve(overrides = {}, token: TOKEN, dq: true)
    Api::SocialApproval::RATE_LIMIT_STORE.clear
    params = { platform: "x", slug: "vistra-corporation", text: TEXT, link: @link, sha256: Digest::SHA256.hexdigest("#{TEXT}\n\n#{@link}"), graders: %w[GTM Founder DQ] }.merge(overrides)
    SocialApproval.find_or_create_by!(platform: params[:platform], slug: params[:slug], sha256: params[:sha256], approved_by: "agent:data-quality") if dq && params[:sha256].to_s.match?(/\A\h{64}\z/) && SocialChannel::PLATFORMS.include?(params[:platform])
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

  test "Data Quality's recorded PASS of the exact hash is required, and an edited text needs a new one (#897)" do
    approve({}, dq: false)
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["codes"], "dq_approval"
    assert_equal 0, SocialPost.count

    # DQ records its PASS with its own token.
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest("dq-token")
    sha = Digest::SHA256.hexdigest("#{TEXT}\n\n#{@link}")
    post api_dq_social_approvals_path, params: { platform: "x", slug: "vistra-corporation", sha256: sha, note: "graded against the release" }, headers: { "Authorization" => "Bearer dq-token" }, as: :json
    assert_response :created
    post api_dq_social_approvals_path, params: { platform: "x", slug: "vistra-corporation", sha256: sha }, headers: { "Authorization" => "Bearer dq-token" }, as: :json
    assert_response :ok
    post api_dq_social_approvals_path, params: { platform: "x", slug: "vistra-corporation", sha256: "nothex" }, headers: { "Authorization" => "Bearer dq-token" }, as: :json
    assert_response :unprocessable_entity
    post api_dq_social_approvals_path, params: { platform: "x", slug: "vistra-corporation", sha256: sha }, headers: { "Authorization" => "Bearer #{TOKEN}" }, as: :json
    assert_response :unauthorized, "the approvals take DQ's token, not the endpoint's"

    approve({}, dq: false)
    assert_response :created
    SocialPost.delete_all
    edited = "#{TEXT} Extra."
    approve({ text: edited, sha256: Digest::SHA256.hexdigest("#{edited}\n\n#{@link}") }, dq: false)
    assert_response :unprocessable_entity, "a new text, a new hash, no approval on file"
    assert_includes response.parsed_body["codes"], "dq_approval"
  ensure
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
  end

  test "refusals come with stable codes" do
    approve({ graders: %w[GTM] })
    assert_includes response.parsed_body["codes"], "graders"
    approve({ slug: "nobody" })
    assert_includes response.parsed_body["codes"], "company"
    approve({ link: "https://nuclear-directory.org/companies/vistra-corporation" })
    assert_includes response.parsed_body["codes"], "link"
    approve({ sha256: Digest::SHA256.hexdigest("else") })
    assert_includes response.parsed_body["codes"], "sha256"
    approve({ platform: "mastodon" })
    assert_includes response.parsed_body["codes"], "platform"
    approve({ send_on: "2026-11-22" })
    assert_includes response.parsed_body["codes"], "send_on", "a Sunday"
    assert((response.parsed_body["codes"] - SocialAgent::ApprovedDraft::CODES).empty?)
  end

  test "every shape the content checks call hard is classified hard, so a reworded check can't become a warning (Infra)" do
    item = SocialAgent::Item.new(subject: @company, kind: "spotlight", facts: { "name" => "Vistra Corporation" }, source_url: "https://vistracorp.com", source_quote: "Vistra Corporation generates electricity.", path: "/companies/vistra-corporation", organization_ids: [])
    {
      "Meet Vistra Corporation: see https://example.com for more about it." => /own link/,
      "Meet Vistra Corporation: it generates electricity. #nuclear" => /hashtag/,
      "Meet Vistra Corporation: it generates electricity \u{1F525}" => /emoji/,
      "Meet Vistra Corporation: [placeholder text goes here]" => /placeholder/,
      "Meet Vistra Corporation. #{'It generates electricity. ' * 14}" => /too long/
    }.each do |text, shape|
      found = SocialAgent::Check.problems(text, item, platform: "x").grep(shape)
      assert found.any?, "the real check no longer says #{shape.inspect} for #{text[0, 40].inspect}"
      assert found.all? { |problem| problem.match?(SocialAgent::ApprovedDraft::HARD) }, "#{found.inspect} must match HARD"
    end
  end

  test "send_on: the 8:30 job sends today's approved draft even on Drafts only; Off stops it; a draft for another day waits; the agent never writes over it (#897)" do
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    sent = []
    SocialAgent.senders["x"] = ->(text, link) { sent << [ text, link ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
    travel_to(Time.find_zone(SocialAgent::ZONE).local(2026, 11, 20, 14, 0)) { approve({ send_on: "2026-11-23" }) }
    assert_response :created
    post = SocialPost.last
    assert_equal Date.new(2026, 11, 23), post.send_on

    travel_to(Time.find_zone(SocialAgent::ZONE).local(2026, 11, 20, 8, 30)) do
      assert_nil SocialAgent.send_scheduled("x"), "Friday isn't its day"
      assert_empty sent
    end
    SocialChannel.for("x").update!(mode: "off")
    travel_to(monday) do
      assert_nil SocialAgent.send_scheduled("x")
      assert_empty sent, "Off stops it"
      assert_equal "drafted", post.reload.status
      assert_match(/approved draft #{post.id} not sent: X is switched off/, CrawlRun.where(source_kind: SocialAgent::STOPPED).order(:id).last.stats["stopped"])
    end
    # On Drafts only but with sending off on the server, today's approved draft isn't out, and the agent doesn't write another over it.
    SocialChannel.for("x").update!(mode: "drafts")
    ENV.delete("SOCIAL_POSTING_ENABLED")
    travel_to(monday) do
      assert_nil SocialAgent.send_scheduled("x")
      assert_nil SocialAgent.run("x", now: monday, writer: Object.new), "the agent leaves today's slot to the approved draft"
      assert_match(/graders-approved draft is scheduled for today/, CrawlRun.where(source_kind: SocialAgent::STOPPED).order(:id).last.stats["stopped"])
    end
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    travel_to(monday) { SocialPostJob.perform_now }
    assert_equal [ [ TEXT, @link ] ], sent
    assert_equal "posted", post.reload.status
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end

  test "at send the approved draft's source must still answer 200 (a release taken down stops it, the draft stays)" do
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    SocialAgent.senders["x"] = ->(*) { flunk "never sent with a dead source" }
    travel_to(monday - 3.days) { approve({ send_on: "2026-11-23", source_url: "https://investor.vistracorp.com/release" }) }
    post = SocialPost.last
    gone = Struct.new(:x) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: :error, status: 404, body: "", etag: nil, last_modified: nil, reason: "gone", block_reference: nil, content_type: "text/html", truncated: false) }
    travel_to(monday) do
      sent, why = SocialAgent.send_draft(post, now: monday, fetcher: gone.new)
      assert_match(/its source page no longer answers \(404\)/, why)
      assert_equal "drafted", post.reload.status, "the draft stays so it can go when the source answers"
    end
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end

  test "the content checks' warnings are stored and shown on the row, with the day it goes out" do
    approve({ send_on: "2026-11-23" })
    post = SocialPost.last
    assert post.warnings.present?
    assert_equal response.parsed_body["warnings"], post.warnings.split("\n")
  end

  def load_row(platform:, slug: "vistra-corporation", send_on:, text: TEXT)
    link = "https://nuclear-directory.org/companies/#{slug}?utm_source=#{platform}&utm_medium=social&utm_campaign=#{slug}"
    approve({ platform:, slug:, link:, text:, sha256: Digest::SHA256.hexdigest(platform == "x" ? "#{text}\n\n#{link}" : text), send_on: })
  end

  test "an approved QUEUE: rows for several days wait, one per platform per day, the same company on two platforms on different days is fine, and waiting rows hold no slot or cooldown" do
    load_row(platform: "x", send_on: "2026-11-23")
    assert_response :created
    load_row(platform: "linkedin", send_on: "2026-11-24")
    assert_response :created, response.parsed_body.inspect
    other = Organization.create!(name: "Energy Northwest", slug: "energy-northwest", website: "https://energy-northwest.com", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago, description: "Public power agency.")
    load_row(platform: "x", slug: "energy-northwest", send_on: "2026-11-23", text: "Meet Energy Northwest. It owns and operates Columbia Generating Station in Richland, WA.")
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["codes"], "send_on_taken", "one approved row per platform per day"
    load_row(platform: "x", slug: "energy-northwest", send_on: "2026-11-24", text: "Meet Energy Northwest. It owns and operates Columbia Generating Station in Richland, WA.")
    assert_response :created
    assert_equal 3, SocialPost.waiting.count
    load_row(platform: "x", send_on: "2026-12-04")
    assert_response :unprocessable_entity, "the same company again on X within 14 days of its queued day"
    assert_includes response.parsed_body["codes"], "cooldown"
    # A waiting row holds no slot: the used scope (today's slot, similarity) ignores it.
    assert_equal 0, SocialPost.used.count
  end

  test "the 8:30 job sends today's row even though the same company waits on another platform for tomorrow; the guards read the queue as waiting, not as tried" do
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    SocialChannel.for("linkedin").update!(mode: "drafts")
    sent = []
    SocialAgent.senders["x"] = ->(text, link) { sent << [ :x, text ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
    SocialAgent.senders["linkedin"] = ->(*) { flunk "LinkedIn's row is for tomorrow" }
    travel_to(Time.find_zone(SocialAgent::ZONE).local(2026, 11, 20, 14, 0)) do
      load_row(platform: "x", send_on: "2026-11-23")
      load_row(platform: "linkedin", send_on: "2026-11-24")
    end
    travel_to(Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)) { SocialPostJob.perform_now }
    assert_equal [ [ :x, TEXT ] ], sent
    assert_equal %w[posted drafted], SocialPost.order(:id).pluck(:status)
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
    SocialAgent.senders.delete("linkedin")
  end

  test "at send the hash, DQ's approval on file and the text's hard problems are checked again; a changed row never goes out" do
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    SocialAgent.senders["x"] = ->(*) { flunk "never sent" }
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)
    travel_to(monday - 3.days) { load_row(platform: "x", send_on: "2026-11-23") }
    post = SocialPost.last
    travel_to(monday) do
      post.update_columns(text: "#{TEXT} Edited.")
      assert_match(/no longer matches the hash the graders approved/, SocialAgent.send_draft(post.reload, now: monday).last)
      post.update_columns(text: TEXT)
      SocialApproval.delete_all
      assert_match(/approval of its hash is no longer on file/, SocialAgent.send_draft(post.reload, now: monday).last)
      assert_equal "drafted", post.reload.status
    end
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end

  test "the job only DRAFTS what the agent writes, never sends it, even on a Live platform" do
    calls = []
    original = SocialAgent.method(:run)
    SocialAgent.singleton_class.send(:define_method, :run) { |platform, **options| calls << [ platform, options[:drafts_only] ] }
    SocialPostJob.perform_now
    assert_equal [ [ "x", true ], [ "linkedin", true ] ], calls
  ensure
    SocialAgent.singleton_class.send(:define_method, :run, original)
  end

  test "a LinkedIn draft can carry the card description the graders approved; the sender uses it instead of the page's meta description (GTM: NuScale/Holtec)" do
    link = @link.sub("utm_source=x", "utm_source=linkedin")
    approve({ platform: "linkedin", link:, sha256: Digest::SHA256.hexdigest(TEXT), card_description: "Announced plan for 24 modules at planned sites." })
    assert_response :created
    post = SocialPost.last
    assert_equal "Announced plan for 24 modules at planned sites.", post.card_description

    ENV.update("BUFFER_API_KEY" => "dummy", "BUFFER_X_CHANNEL_ID" => "ch-x", "BUFFER_LINKEDIN_CHANNEL_ID" => "ch-li")
    seen = []
    page = { url: link, title: "Vistra Corporation", description: "Supplies Standard Power", thumbnail: { url: "https://nuclear-directory.org/c.png" } }
    buffer = SocialAgent::Buffer.new(http: ->(request) { seen << JSON.parse(request.body); { "data" => { "createPost" => { "post" => { "id" => "p", "dueAt" => "2026-11-23T16:45:00Z" } } } } }, card: ->(_) { page })
    buffer.call("linkedin", TEXT, link, card_description: post.card_description)
    assert_equal "Announced plan for 24 modules at planned sites.", seen.last["variables"]["input"].dig("metadata", "linkedin", "linkAttachment", "description")
    buffer.call("linkedin", TEXT, link)
    assert_equal "Supplies Standard Power", seen.last["variables"]["input"].dig("metadata", "linkedin", "linkAttachment", "description"), "no override: the page's own"

    SocialPost.delete_all
    approve({ card_description: "ignored on X" })
    assert_nil SocialPost.last.card_description, "X's card comes from the page"
  end
end
