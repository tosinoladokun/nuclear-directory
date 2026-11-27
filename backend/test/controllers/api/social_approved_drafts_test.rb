require "test_helper"

# #896: graders-approved spotlight drafts reach Admin > Posts without a console step, and are never sent from the endpoint.
class Api::SocialApprovedDraftsTest < ActionDispatch::IntegrationTest
  TOKEN = "approve-token"
  BY = "human:tosin"
  PAGE = Struct.new(:x) do
    def get(url, **) = DataQuality::Fetcher::Response.new(url: "", kind: :ok, status: 200, body: "<p>Vistra generates electricity in Irving.</p>", etag: nil, last_modified: nil, reason: "x", block_reference: nil,
      content_type: url.to_s.end_with?(".png") ? "image/png" : "text/html", truncated: false)
  end
  # Tests that name a send_on freeze the clock before it (a date in the past is refused), so they keep passing after those days.
  FRIDAY = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 20, 12, 0)
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
    # A LinkedIn post always carries its card and content hash (DQ): added here unless the test gives its own.
    if params[:platform] == "linkedin" && !overrides.key?(:card)
      params[:card] = { title: "Card title", description: "Card description.", image_url: "https://nuclear-directory.org/cards/x.png" }
      params[:annotations] ||= []
      params[:content_payload_sha256] = SocialAgent::ApprovedDraft.content_hash(text: params[:text].to_s.strip, link: params[:link], annotations: params[:annotations], card: params[:card].stringify_keys)
    end
    if dq && SocialChannel::PLATFORMS.include?(params[:platform])
      [ params[:sha256], params[:content_payload_sha256] ].compact.select { |sha| sha.to_s.match?(/\A\h{64}\z/) }.each do |sha|
        SocialApproval.find_or_create_by!(platform: params[:platform], slug: params[:slug], sha256: sha, approved_by: "agent:data-quality")
      end
    end
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

  test "an X draft tagging the company's own verified handle gets no handle warning; another handle does (#1007)" do
    own = "#{TEXT}\n\n@VistraCorp"
    approve({ text: own, sha256: Digest::SHA256.hexdigest("#{own}\n\n#{@link}") })
    assert_response :created
    warnings = response.parsed_body["warnings"]
    assert warnings.none? { |warning| warning.match?(/verified handle|"VistraCorp"/) }, warnings.inspect

    SocialPost.delete_all
    other = "#{TEXT}\n\n@SomeoneElse"
    approve({ text: other, sha256: Digest::SHA256.hexdigest("#{other}\n\n#{@link}") })
    assert_response :created
    assert response.parsed_body["warnings"].any? { |warning| warning.match?(/@SomeoneElse, which isn't this company's verified handle/) }, response.parsed_body["warnings"].inspect
  end

  test "Send this draft sends an approved draft exactly as stored after the guards, without the content recheck, and the DQ API says how it was approved" do
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 10, 0)
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    sent = []
    SocialAgent.senders["x"] = ->(text, link, **) { sent << [ text, link ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
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
    travel_to(FRIDAY) do
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
    SocialAgent.senders["x"] = ->(text, link, **) { sent << [ text, link ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
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
    travel_to(FRIDAY) do
      approve({ send_on: "2026-11-23" })
      post = SocialPost.last
      assert post.warnings.present?
      assert_equal response.parsed_body["warnings"], post.warnings.split("\n")
    end
  end

  def load_row(platform:, slug: "vistra-corporation", send_on:, text: TEXT)
    link = "https://nuclear-directory.org/companies/#{slug}?utm_source=#{platform}&utm_medium=social&utm_campaign=#{slug}"
    approve({ platform:, slug:, link:, text:, sha256: Digest::SHA256.hexdigest(platform == "x" ? "#{text}\n\n#{link}" : text), send_on: })
  end

  test "an approved QUEUE: rows for several days wait, one per platform per day, the same company on two platforms on different days is fine, and waiting rows hold no slot or cooldown" do
    travel_to(FRIDAY) do
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
  end

  test "the 8:30 job sends today's row even though the same company waits on another platform for tomorrow; the guards read the queue as waiting, not as tried" do
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    SocialChannel.for("linkedin").update!(mode: "drafts")
    sent = []
    SocialAgent.senders["x"] = ->(text, link, **) { sent << [ :x, text ]; { id: "9", permalink: "https://x.com/i/web/status/9" } }
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

  test "a second send on the same platform and day is impossible, in the guards and in the database (Backend)" do
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("x").update!(mode: "drafts")
    sent = []
    SocialAgent.senders["x"] = ->(text, _link, **) { sent << text; { id: "9", permalink: "https://x.com/i/web/status/9" } }
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)
    travel_to(monday - 3.days) { load_row(platform: "x", send_on: "2026-11-23") }
    approved = SocialPost.last
    other_company = Organization.create!(name: "Energy Northwest", slug: "energy-northwest", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    plain = SocialPost.create!(platform: "x", status: "drafted", subject: other_company, text: "Meet Energy Northwest. A plain draft.", link: "https://nuclear-directory.org/companies/energy-northwest",
      organization_ids: [ other_company.id ], created_at: monday - 1.hour)
    travel_to(monday) do
      assert_nil SocialAgent.send_draft(approved, now: monday).last
      assert_equal [ TEXT ], sent
      _, why = SocialAgent.send_draft(plain, now: monday)
      assert_match(/today's slot for this platform is already taken/, why)
      assert_equal "drafted", plain.reload.status
      assert_equal 1, sent.size

      # Even if a guard were missed (two requests racing), the database refuses a second claim for the platform and day.
      assert_raises(ActiveRecord::RecordNotUnique) { ActiveRecord::Base.transaction(requires_new: true) { plain.update_columns(status: "sending", sent_on: monday.to_date) } }
      assert_equal 1, SocialPost.where(platform: "x", sent_on: monday.to_date, status: SocialPost::SENT).count
      plain.update_columns(sent_on: monday.to_date, status: "failed")
      assert_equal "failed", plain.reload.status, "a failed attempt frees the day's index"
    end
    # The next weekday is a new day: the slot is free again.
    plain.update_columns(status: "drafted", sent_on: nil, created_at: monday + 1.day - 1.hour)
    travel_to(monday + 1.day) { assert_nil SocialAgent.draft_refusal(plain, monday + 1.day), "a new day, a free slot" }
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("x")
  end

  test "social_approvals is a private table for Metabase" do
    assert_includes Metabase::ReadonlyRole::PRIVATE_TABLES, "social_approvals"
  end

  test "graders' approval survives the outcome: a Buffer timeout or a taken-back post rewrites the reason, and the DQ API still says approved by the graders, never 'passed every check' (Copilot)" do
    travel_to(FRIDAY) { approve({ send_on: "2026-11-23" }) }
    post = SocialPost.last
    post.update!(status: "unknown", reason: "may have gone out (timeout); check the account, never resent")
    assert post.reload.graded?
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest("dq")
    get api_dq_social_posts_path, params: { since: "2026-11-01" }, headers: { "Authorization" => "Bearer dq" }
    assert_equal Api::Dq::SocialPostsController::GRADED, response.parsed_body["posts"].last["checks"]
    assert_not SocialPost.new(reason: "approved by graders: GTM", approved_sha256: nil).graded?, "a reason alone claims nothing"
  ensure
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
  end

  test "caps count a post by the day it was sent: a November draft sent in December counts in December's cap and today's slot (Copilot)" do
    company = Organization.create!(name: "Acme Fission", slug: "acme-fission", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    sent_dec = SocialPost.create!(platform: "x", status: "posted", subject: company, text: "Meet Acme.", cost_usd: 0.5, created_at: Time.utc(2026, 11, 20, 20), sent_on: Date.new(2026, 12, 1))
    december = Time.find_zone(SocialAgent::ZONE).local(2026, 12, 15, 9)
    assert_includes SocialPost.where(status: SocialPost::SENT).in_month(december), sent_dec
    assert_not_includes SocialPost.where(status: SocialPost::SENT).in_month(Time.find_zone(SocialAgent::ZONE).local(2026, 11, 15)), sent_dec
    assert_includes SocialPost.on_day(Time.find_zone(SocialAgent::ZONE).local(2026, 12, 1, 8, 30)), sent_dec
    assert_not_includes SocialPost.on_day(Time.find_zone(SocialAgent::ZONE).local(2026, 11, 20, 8, 30)), sent_dec
    third = Organization.create!(name: "Gamma Fission", slug: "gamma-fission", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    legacy = SocialPost.create!(platform: "x", status: "posted", subject: third, text: "Old.", created_at: Time.utc(2026, 12, 2, 18))
    assert_includes SocialPost.in_month(december), legacy, "an older row without sent_on falls back to created_at"
    ENV["SOCIAL_MONTHLY_MAX"] = "1"
    other = Organization.create!(name: "Beta Fission", slug: "beta-fission", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    SocialChannel.for("x")
    draft = SocialPost.create!(platform: "x", status: "drafted", subject: other, text: "Meet Beta.", created_at: december - 1.hour)
    SocialAgent.senders["x"] = ->(*) { flunk "over the month's cap" }
    assert_match(/this month's 1 posts are done/, SocialAgent.send_post(draft, now: december).reason)
  ensure
    ENV.delete("SOCIAL_MONTHLY_MAX")
    SocialAgent.senders.delete("x")
  end

  # GTM's TerraPower payloads (schedule JSON v3): the X text with our URL inside and the handle last, and the LinkedIn text with a native mention.
  TERRA_URL_X = "https://nuclear-directory.org/companies/terrapower?utm_source=x&utm_medium=social&utm_campaign=terrapower".freeze
  TERRA_X = "Meet TerraPower.\n\nBased in Bellevue, WA, it is building the Natrium demonstration plant. Its January 2026 Meta agreement covers early development of two new Natrium units.\n\n#{TERRA_URL_X}\n\n@terrapower".freeze
  TERRA_LI = "Meet TerraPower.\n\nBased in Bellevue, WA, it is building the Natrium demonstration plant. Its January 2026 Meta agreement covers early development of two new Natrium units.".freeze
  TERRA_LI_URL = "https://nuclear-directory.org/companies/terrapower?utm_source=linkedin&utm_medium=social&utm_campaign=terrapower".freeze
  TERRA_ANNOTATION = { "id" => "7300927", "entity" => "urn:li:organization:7300927", "length" => 10, "link" => "https://www.linkedin.com/company/terrapower", "localizedName" => "TerraPower", "start" => 5, "vanityName" => "terrapower" }.freeze
  TERRA_CARD = { "title" => "TerraPower", "description" => "Based in Bellevue, WA, it is building the Natrium demonstration plant. Its January 2026 Meta agreement covers early development of two new Natrium units.",
                 "image_url" => "https://nuclear-directory.org/cards/companies/terrapower/3c6cd97de2f87f53.png" }.freeze

  def terrapower!
    Organization.find_by(slug: "terrapower")&.tap { |company| company.update_columns(verification_status: "verified", verified_by: BY, verified_at: 1.year.ago) } ||
      Organization.create!(name: "TerraPower", slug: "terrapower", website: "https://www.terrapower.com", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago, description: "Reactor developer.")
  end

  test "X: the approved text with our URL inside and the handle last is accepted as is, hashed as is, and sent verbatim (no URL appended)" do
    terrapower!
    sha = Digest::SHA256.hexdigest(TERRA_X)
    assert_equal "7bf1c9053398d1f391f5ac058cd135f27c57a7690ea9c4cae167910cab6c2106", sha, "GTM's post_text_sha256"
    travel_to(FRIDAY) { approve({ slug: "terrapower", text: TERRA_X, link: TERRA_URL_X, sha256: sha, send_on: "2026-11-23", opener_pattern_id: "place" }) }
    assert_response :created, response.parsed_body.inspect
    post = SocialPost.last
    assert_equal [ TERRA_X, true, "place" ], [ post.text, post.exact_text, post.opener_pattern_id ]

    ENV.update("BUFFER_API_KEY" => "dummy", "BUFFER_X_CHANNEL_ID" => "ch-x", "BUFFER_LINKEDIN_CHANNEL_ID" => "ch-li")
    seen = []
    buffer = SocialAgent::Buffer.new(http: ->(request) { seen << JSON.parse(request.body); { "data" => { "createPost" => { "post" => { "id" => "p", "dueAt" => "2026-11-23T16:45:00Z" } } } } }, card: ->(_) { flunk "no page read" })
    buffer.call("x", post.text, post.link, exact: true, strict: true)
    assert_equal TERRA_X, seen.last["variables"]["input"]["text"], "verbatim: the URL isn't appended again"
    assert_equal 1, seen.last["variables"]["input"]["text"].scan("https://").size
  end

  test "X exact text: another URL, a wrong hash, or over 280 weighted characters is refused" do
    terrapower!
    two = "#{TERRA_X} https://example.com/x"
    approve({ slug: "terrapower", text: two, link: TERRA_URL_X, sha256: Digest::SHA256.hexdigest(two) })
    assert_includes response.parsed_body["codes"], "url_in_text"
    approve({ slug: "terrapower", text: TERRA_X, link: TERRA_URL_X, sha256: Digest::SHA256.hexdigest("#{TERRA_X}\n\n#{TERRA_URL_X}") })
    assert_includes response.parsed_body["codes"], "sha256", "an exact text hashes as itself, not text + link"
    long = TERRA_X.sub("Meet TerraPower.", "Meet TerraPower. #{'Padding sentence here. ' * 8}")
    approve({ slug: "terrapower", text: long, link: TERRA_URL_X, sha256: Digest::SHA256.hexdigest(long) })
    assert_includes response.parsed_body["codes"], "length"
  end

  test "LinkedIn: native mention + card + the canonical content hash GTM computed (eec98020...), DQ's approval of both hashes, and the payload is stored for the send" do
    terrapower!
    content = "eec98020fa132e9bd89b0ce5fd0f3b2baba339d1b4d187afeaaf8edc174de90d"
    sha = Digest::SHA256.hexdigest(TERRA_LI)
    body = { platform: "linkedin", slug: "terrapower", text: TERRA_LI, link: TERRA_LI_URL, sha256: sha, annotations: [ TERRA_ANNOTATION ], card: TERRA_CARD, content_payload_sha256: content, send_on: "2026-11-24" }
    SocialApproval.create!(platform: "linkedin", slug: "terrapower", sha256: sha, approved_by: "agent:data-quality")
    travel_to(FRIDAY) { approve(body, dq: false) }
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["codes"], "dq_approval", "the content hash needs DQ's approval too"

    SocialApproval.create!(platform: "linkedin", slug: "terrapower", sha256: content, approved_by: "agent:data-quality")
    travel_to(FRIDAY) { approve(body, dq: false) }
    assert_response :created, response.parsed_body.inspect
    post = SocialPost.last
    assert_equal [ [ TERRA_ANNOTATION ], TERRA_CARD, content, false ], [ post.annotations, post.card, post.content_payload_sha256, post.exact_text ]

    # A different name offset, a wrong urn, or a changed card changes what is approved: refused.
    SocialPost.delete_all
    travel_to(FRIDAY) { approve(body.merge(annotations: [ TERRA_ANNOTATION.merge("start" => 6) ]), dq: false) }
    assert_includes response.parsed_body["codes"], "annotations"
    travel_to(FRIDAY) { approve(body.merge(annotations: [ TERRA_ANNOTATION.merge("entity" => "urn:li:organization:1") ]), dq: false) }
    assert_includes response.parsed_body["codes"], "annotations"
    travel_to(FRIDAY) { approve(body.merge(card: TERRA_CARD.merge("description" => "Something else")), dq: false) }
    assert_includes response.parsed_body["codes"], "content_sha"
  end

  test "the sender sends the approved LinkedIn payload exactly: annotations and card as approved, no page read, and no fallback: a refusal fails the post, nothing changed is posted" do
    ENV.update("BUFFER_API_KEY" => "dummy", "BUFFER_X_CHANNEL_ID" => "ch-x", "BUFFER_LINKEDIN_CHANNEL_ID" => "ch-li")
    seen = []
    replies = []
    buffer = SocialAgent::Buffer.new(http: ->(request) { seen << JSON.parse(request.body); replies.shift }, card: ->(_) { flunk "the approved card is used, the page isn't read" })
    replies << { "data" => { "createPost" => { "post" => { "id" => "p", "dueAt" => "2026-11-24T16:45:00Z" } } } }
    buffer.call("linkedin", TERRA_LI, TERRA_LI_URL, card: TERRA_CARD.transform_keys(&:to_sym), annotations: [ TERRA_ANNOTATION ], strict: true)
    meta = seen.last["variables"]["input"]["metadata"]["linkedin"]
    assert_equal TERRA_LI, seen.last["variables"]["input"]["text"]
    assert_equal [ TERRA_ANNOTATION ], meta["annotations"]
    assert_equal({ "url" => TERRA_LI_URL, "title" => "TerraPower", "description" => TERRA_CARD["description"], "thumbnail" => { "url" => TERRA_CARD["image_url"] } }, meta["linkAttachment"])

    seen.clear
    replies << { "data" => { "createPost" => { "message" => "Daily limit reached" } } }
    assert_raises(SocialAgent::Buffer::Error) { buffer.call("linkedin", TERRA_LI, TERRA_LI_URL, card: TERRA_CARD.transform_keys(&:to_sym), annotations: [ TERRA_ANNOTATION ], strict: true) }
    assert_equal 1, seen.size, "a refusal that isn't about the card is never retried"

    # A DEFINITE card refusal: the post may go with the URL inline, the mentions kept, and the fallback reported (PM, 21 Nov).
    seen.clear
    replies << { "data" => { "createPost" => { "message" => "Invalid link attachment thumbnail" } } } << { "data" => { "createPost" => { "post" => { "id" => "p2", "dueAt" => "2026-11-24T16:45:00Z" } } } }
    sent = buffer.call("linkedin", TERRA_LI, TERRA_LI_URL, card: TERRA_CARD.transform_keys(&:to_sym), annotations: [ TERRA_ANNOTATION ], strict: true)
    assert_equal 2, seen.size
    assert_equal "#{TERRA_LI}\n\n#{TERRA_LI_URL}", seen.last["variables"]["input"]["text"]
    assert_equal [ TERRA_ANNOTATION ], seen.last["variables"]["input"].dig("metadata", "linkedin", "annotations"), "mentions kept"
    assert_nil seen.last["variables"]["input"].dig("metadata", "linkedin", "linkAttachment")
    assert_match(/Buffer refused the card .*posted with the URL inline and the mentions kept/, sent[:fallback])

    # An uncertain reply is never retried.
    seen.clear
    replies << { "data" => {} }
    assert_raises(SocialAgent::Uncertain) { buffer.call("linkedin", TERRA_LI, TERRA_LI_URL, card: TERRA_CARD.transform_keys(&:to_sym), annotations: [ TERRA_ANNOTATION ], strict: true) }
    assert_equal 1, seen.size
    unreadable = SocialAgent::Buffer.new(http: ->(_) { flunk "nothing is sent" }, card: ->(_) { nil })
    assert_raises(SocialAgent::Buffer::Error) { unreadable.call("linkedin", TERRA_LI, TERRA_LI_URL, strict: true) }
  end

  test "an opener pattern used in the last five posts on the platform is refused (opener_repeat); the queue can be read back with its hashes" do
    travel_to(FRIDAY) do
      load_row(platform: "x", send_on: "2026-11-23")
      assert_response :created
    end
    SocialPost.last.update!(opener_pattern_id: "label")
    other = Organization.create!(name: "Energy Northwest", slug: "energy-northwest", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    text = "Energy Northwest: it owns and operates Columbia Generating Station."
    link = "https://nuclear-directory.org/companies/energy-northwest?utm_source=x&utm_medium=social&utm_campaign=energy-northwest"
    travel_to(FRIDAY) { approve({ slug: "energy-northwest", link:, text:, sha256: Digest::SHA256.hexdigest("#{text}\n\n#{link}"), send_on: "2026-11-24", opener_pattern_id: "label" }) }
    assert_includes response.parsed_body["codes"], "opener_repeat"
    travel_to(FRIDAY) { approve({ slug: "energy-northwest", link:, text:, sha256: Digest::SHA256.hexdigest("#{text}\n\n#{link}"), send_on: "2026-11-24", opener_pattern_id: "activity" }) }
    assert_response :created

    get api_social_approved_drafts_path, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :success
    queue = response.parsed_body["queue"]
    assert_equal [ [ "2026-11-23", "x", "vistra-corporation" ], [ "2026-11-24", "x", "energy-northwest" ] ], queue.map { |row| row.values_at("send_on", "platform", "company") }
    assert_equal Digest::SHA256.hexdigest(queue.first["approved_sha256"] ? SocialPost.find(queue.first["id"]).text : ""), queue.first["text_sha256"]
    get api_social_approved_drafts_path
    assert_response :unauthorized
  end

  test "a holiday send_on is refused (Thanksgiving), and the job sends every platform's approved row before any model draft" do
    travel_to(FRIDAY) do
      load_row(platform: "x", send_on: "2026-11-26")
      assert_response :unprocessable_entity
      assert_includes response.parsed_body["codes"], "send_on"
      assert_match(/is a holiday/, response.parsed_body["errors"].join)
    end
    order = []
    send_original = SocialAgent.method(:send_scheduled)
    run_original = SocialAgent.method(:run)
    SocialAgent.singleton_class.send(:define_method, :send_scheduled) { |platform, **| order << [ :send, platform ] }
    SocialAgent.singleton_class.send(:define_method, :run) { |platform, **| order << [ :draft, platform ] }
    SocialPostJob.perform_now
    assert_equal [ [ :send, "x" ], [ :send, "linkedin" ], [ :draft, "x" ], [ :draft, "linkedin" ] ], order
  ensure
    SocialAgent.singleton_class.send(:define_method, :send_scheduled, send_original)
    SocialAgent.singleton_class.send(:define_method, :run, run_original)
  end

  test "a LinkedIn post always carries its card and content hash, and at SEND the content hash is recomputed from the stored row and DQ's approval of it must still be on file (DQ)" do
    link = @link.sub("utm_source=x", "utm_source=linkedin")
    sha = Digest::SHA256.hexdigest(TEXT)
    SocialApproval.create!(platform: "linkedin", slug: "vistra-corporation", sha256: sha, approved_by: "agent:data-quality")
    travel_to(FRIDAY) { approve({ platform: "linkedin", link:, sha256: sha, card: nil, content_payload_sha256: nil, send_on: "2026-11-23" }, dq: false) }
    assert_response :unprocessable_entity
    assert((response.parsed_body["codes"] & %w[card content_sha]).any?, "no card, no content hash: refused")

    travel_to(FRIDAY) { approve({ platform: "linkedin", link:, sha256: sha, send_on: "2026-11-23" }) }
    assert_response :created, response.parsed_body.inspect
    post = SocialPost.last
    assert post.content_payload_sha256.present?
    monday = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 23, 8, 30)
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
    SocialChannel.for("linkedin").update!(mode: "drafts")
    SocialAgent.senders["linkedin"] = ->(*, **) { flunk "never sent" }
    travel_to(monday) do
      post.update_columns(card: post.card.merge("description" => "Edited after approval."))
      assert_match(/content no longer matches the content hash the graders approved/, SocialAgent.send_draft(post.reload, now: monday).last)
      post.update_columns(card: post.card.merge("description" => "Card description."))
      SocialApproval.where(sha256: post.content_payload_sha256).delete_all
      assert_match(/approval of its content hash is no longer on file/, SocialAgent.send_draft(post.reload, now: monday).last)
      post.update_columns(card: nil)
      assert_match(/card or content hash is missing/, SocialAgent.send_draft(post.reload, now: monday).last)
      assert_equal "drafted", post.reload.status, "nothing was claimed or sent"
    end
  ensure
    ENV.delete("SOCIAL_POSTING_ENABLED")
    SocialAgent.senders.delete("linkedin")
  end

  test "the card's image must answer 200 as an image when the post is loaded (Infra: a dead thumbnail would fail a strict send and pause the channel)" do
    link = @link.sub("utm_source=x", "utm_source=linkedin")
    gone = Struct.new(:x) { def get(_url, **) = DataQuality::Fetcher::Response.new(url: "", kind: :error, status: 404, body: "", etag: nil, last_modified: nil, reason: "gone", block_reference: nil, content_type: "text/html", truncated: false) }
    SocialAgent::ApprovedDraft.fetcher = gone.new
    travel_to(FRIDAY) { approve({ platform: "linkedin", link:, sha256: Digest::SHA256.hexdigest(TEXT), send_on: "2026-11-23" }) }
    assert_response :unprocessable_entity
    assert_match(/image_url doesn't answer 200/, response.parsed_body["errors"].join)
    SocialAgent::ApprovedDraft.fetcher = PAGE.new
    travel_to(FRIDAY) { approve({ platform: "linkedin", link:, sha256: Digest::SHA256.hexdigest(TEXT), send_on: "2026-11-23" }) }
    assert_response :created
  end

  test "Copilot (#900): an exact X draft passes the send-time recheck (its prose is read without our URL), and a changed URL or hash is refused" do
    terrapower!
    sha = Digest::SHA256.hexdigest(TERRA_X)
    travel_to(FRIDAY) { approve({ slug: "terrapower", text: TERRA_X, link: TERRA_URL_X, sha256: sha, send_on: "2026-11-23" }) }
    assert_response :created, response.parsed_body.inspect
    post = SocialPost.last
    assert post.exact_text
    assert_nil SocialAgent.recheck(post, FRIDAY, PAGE.new), "the exact text, its link once, its weight and its prose still pass"

    post.update_columns(text: "#{TERRA_X}\nhttps://example.org/x")
    assert_match(/no longer matches the hash/, SocialAgent.recheck(post.reload, FRIDAY, PAGE.new), "a second URL changes the hash")
    post.update_columns(text: TERRA_X.sub("TerraPower", "TerraPowe"))
    assert_match(/no longer matches the hash/, SocialAgent.recheck(post.reload, FRIDAY, PAGE.new))
  end

  test "Copilot (#900): a card-only LinkedIn payload hashes what the sender sends: no annotations key at all" do
    card = TERRA_CARD
    with_none = SocialAgent::ApprovedDraft.content_hash(text: "x", link: "https://nuclear-directory.org/a", annotations: [], card:)
    assert_equal with_none, SocialAgent::ApprovedDraft.content_hash(text: "x", link: "https://nuclear-directory.org/a", annotations: nil, card:)
    refute_equal with_none, SocialAgent::ApprovedDraft.content_hash(text: "x", link: "https://nuclear-directory.org/a", annotations: [ TERRA_ANNOTATION ], card:)
  end

  test "Copilot (#900): the readback's last-sent list follows the day each went out, not the order they were loaded" do
    travel_to(FRIDAY) { load_row(platform: "x", send_on: "2026-11-23") }
    first = SocialPost.last
    other = Organization.create!(name: "Energy Northwest", slug: "energy-northwest", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    link = "https://nuclear-directory.org/companies/energy-northwest?utm_source=x&utm_medium=social&utm_campaign=energy-northwest"
    text = "Energy Northwest: it owns and operates Columbia Generating Station."
    travel_to(FRIDAY) { approve({ slug: "energy-northwest", link:, text:, sha256: Digest::SHA256.hexdigest("#{text}\n\n#{link}"), send_on: "2026-11-24" }) }
    second = SocialPost.last
    assert_equal other, second.subject
    first.update_columns(status: SocialPost::SENT.first, sent_on: Date.new(2026, 11, 25))
    second.update_columns(status: SocialPost::SENT.first, sent_on: Date.new(2026, 11, 23))
    get api_social_approved_drafts_path, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_equal [ first.id, second.id ], response.parsed_body["sent"].map { |row| row["id"] }, "the later send day first, though it was loaded first"
  end
end
