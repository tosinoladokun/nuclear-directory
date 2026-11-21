require "test_helper"

# The social agent (#769): one checked post per platform each weekday about fresh, published directory data.
class SocialAgentTest < ActiveSupport::TestCase
  BY = "human:tosin"
  MONDAY = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 16, 8, 30)

  # Writes what it's told and judges with the answer it's given; no model call.
  class FakeWriter
    attr_accessor :text, :voice
    def initialize(text, voice: [ true, nil ]) = (@text, @voice = text, voice)
    def draft(_item, platform:, crawl_run: nil, feedback: nil, previous: nil) = text.respond_to?(:call) ? text.call : text
    def voice_ok?(_text, _item, crawl_run: nil) = voice
  end

  setup do
    @company = Organization.create!(name: "Acme Fission", slug: "acme-fission", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    @news = NewsItem.create!(url: "https://www.energy.gov/acme-award", title: "Acme Fission wins $1,404,253 DOE award for fuel cladding",
      summary: "The Department of Energy said it awarded Acme Fission $1,404,253 to test fuel cladding.", publisher: "DOE",
      published_on: Date.new(2026, 11, 12), verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.day)
    @news.news_mentions.create!(subject: @company)
    SocialChannel.for("x").update!(mode: "drafts")
    ENV["SOCIAL_POST_KINDS"] = "news,link,new_company"
  end

  teardown { ENV.delete("SOCIAL_POST_KINDS") }

  # The source answers 200 (no network in tests).
  OK_FETCHER = Struct.new(:status) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: status == 200 ? :ok : :error, status:, body: "<p>Published November 12, 2026</p>", etag: nil,
    last_modified: nil, reason: "x", block_reference: nil, content_type: "text/html", truncated: false) }

  def run_x(text, fetcher: OK_FETCHER.new(200), **options) = SocialAgent.run("x", now: MONDAY, writer: FakeWriter.new(text, **options), fetcher:)

  test "drafts one checked post on the freshest published news, linked to its company with tracking" do
    post = run_x("The Department of Energy said it awarded Acme Fission $1,404,253 to test fuel cladding.")
    assert_equal [ "drafted", @news ], [ post.status, post.subject ]
    assert_equal "https://nuclear-directory.org/companies/acme-fission?utm_source=x&utm_medium=social&utm_campaign=acme-fission", post.link
    assert_equal "https://www.energy.gov/acme-award", post.source_url
    assert_nil run_x("Again."), "one a day per platform"
  end

  test "a number or name the source doesn't have stops the post, as does the voice check" do
    assert_match "the number 2 isn't in the source", run_x("DOE said Acme Fission won 2 DOE awards.").reason
    SocialPost.delete_all
    assert_match "the name \"Westinghouse\" isn't in the source", run_x("DOE said Acme Fission and Westinghouse won a DOE award.").reason
    SocialPost.delete_all
    assert_match "voice check: reads like an ad", run_x("DOE said Acme Fission won a DOE award.", voice: [ false, "reads like an ad" ]).reason
    SocialPost.delete_all
    assert_match "hashtag", run_x("DOE said Acme Fission won a DOE award. #nuclear").reason
  end

  test "people and event items aren't news; relative time is stopped" do
    @news.update_columns(title: "Acme Fission engineer named to 40 Under 40")
    assert_nil run_x("DOE said Acme Fission won a DOE award.")
    @news.update_columns(title: "Acme Fission wins $1,404,253 DOE award for fuel cladding")
    assert_match "\"today\" instead of a date", run_x("Today DOE said Acme Fission won a DOE award.").reason
  end

  test "off, weekends and nothing fresh post nothing; a fact used in the last two weeks isn't used again" do
    SocialChannel.for("x").update!(mode: "off")
    assert_nil run_x("DOE said Acme Fission won a DOE award.")
    SocialChannel.for("x").update!(mode: "drafts")
    assert_nil SocialAgent.run("x", now: MONDAY - 2.days, writer: FakeWriter.new("DOE said Acme Fission won a DOE award."), fetcher: OK_FETCHER.new(200)), "Saturday"
    SocialPost.create!(platform: "linkedin", status: "posted", subject: @news, created_at: MONDAY - 10.days)
    assert_nil run_x("DOE said Acme Fission won a DOE award."), "used on LinkedIn 10 days ago"
    stopped = CrawlRun.where(source_kind: SocialAgent::STOPPED).where("stats ? 'stopped'").order(:id).map { |run| run.stats.values_at("platform", "stopped") }
    assert_equal [ [ "x", "switched off in Admin > Posts" ], [ "x", "a weekend" ], [ "x", "no fresh item" ] ], stopped, "every silent run says why (PM)"

    SocialChannel.for("x").update!(mode: "off", paused_reason: "Buffer's 30-day request allowance is 80% used")
    run_x("DOE said Acme Fission won a DOE award.")
    assert_equal "Buffer's 30-day request allowance is 80% used", CrawlRun.where(source_kind: SocialAgent::STOPPED).order(:id).last.stats["stopped"]
    today = Today.new(on: MONDAY.in_time_zone(Today::ZONE).to_date, now: MONDAY + 1.hour)
    assert_nil today.checker_ran_at, "a social run is never Joy's check (Copilot)"
  end

  test "a link between two published companies, approved this week with its quote, is picked after news (PM)" do
    @news.update_columns(verified_at: MONDAY - 20.days)
    westinghouse = Organization.create!(name: "Westinghouse", slug: "westinghouse-test", verification_status: "verified", verified_by: BY)
    acme = Organization.find_by!(slug: "acme-fission")
    link = Relationship.create!(from_organization: acme, to_organization: westinghouse, relationship_type: "invests_in",
      description: "a 49 percent holding", verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.day)
    VerificationEvent.where(subject: link).update_all(created_at: MONDAY - 1.day)
    VerificationEvent.create!(subject: link, to_status: "verified", by: BY, created_at: MONDAY - 1.day) unless VerificationEvent.exists?(subject: link, to_status: "verified")
    acme.update!(domain: "acme.example")
    press = Source.create!(url: "https://tradepress.example/acme", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: link, source: press, quote: "Acme Fission and Westinghouse agreed terms.", found_by: "human")
    page = Source.create!(url: "https://acme.example/news", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: link, source: page, quote: "Acme Fission holds a 49% stake in Westinghouse.", found_by: "human")

    item = SocialAgent::Picker.new(platform: "x", now: MONDAY).call
    assert_equal [ "link", link ], [ item.kind, item.subject ]
    assert_equal "Acme Fission invests in Westinghouse", item.facts["link"]
    assert_equal "https://acme.example/news", item.source_url, "the primary source's quote, not the older trade press one (Copilot)"
    assert_nil item.facts["detail"], "'49% stake' isn't the quote's exact words, so the detail stays out (Copilot)"

    link.update!(description: "49% stake")
    assert_equal "49% stake", SocialAgent::Picker.new(platform: "x", now: MONDAY).call.facts["detail"], "now the quote states it"

    link.update!(started_on: MONDAY.to_date + 30)
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.select { |c| c.kind == "link" }, "not in effect yet (Copilot)"
    link.update!(started_on: nil, ended_on: MONDAY.to_date + 30)
    assert_equal [ link ], SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.select { |c| c.kind == "link" }.map(&:subject), "ends later: still in effect"
    westinghouse.update_columns(verification_status: "unpublished")
    assert_not SocialAgent.still_published?(link.reload), "a company taken off stops the send (Copilot)"
    westinghouse.update_columns(verification_status: "verified")

    # A funder's bulk list of awards that week is never a "new deal" post (DQ).
    funder = Organization.create!(name: "ARPA-E", slug: "arpa-e-test", verification_status: "verified", verified_by: BY)
    (SocialAgent::Picker::BULK_LINKS + 1).times do |i|
      to = Organization.create!(name: "Lab #{i}", slug: "lab-#{i}-test", verification_status: "verified", verified_by: BY)
      award = Relationship.create!(from_organization: funder, to_organization: to, relationship_type: "funds", verification_status: "verified",
        verified_by: BY, verified_at: MONDAY - 1.hour)
      VerificationEvent.where(subject: award).update_all(created_at: MONDAY - 1.hour)
      VerificationEvent.create!(subject: award, to_status: "verified", by: BY, created_at: MONDAY - 1.hour) unless VerificationEvent.exists?(subject: award, to_status: "verified")
      Evidence.create!(subject: award, source: page, quote: "ARPA-E funds Lab #{i}.", found_by: "human")
    end
    assert_equal [ link ], SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.select { |c| c.kind == "link" }.map(&:subject)
  end

  test "a newly added company is used when there's no fresh news" do
    @news.update_columns(verified_at: MONDAY - 20.days)
    company = Organization.create!(name: "Beta Reactors", slug: "beta-reactors", domain: "beta.example", description: "Beta Reactors designs small reactors.",
      verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.day)
    VerificationEvent.where(subject: company).update_all(created_at: MONDAY - 1.day)
    page = Source.create!(url: "https://beta.example/about", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: company, source: page, quote: "Beta Reactors designs small reactors.", found_by: "crawler", fields: %w[description])
    VerificationEvent.where(subject: @company).update_all(created_at: MONDAY - 1.day)
    VerificationEvent.create!(subject: @company, to_status: "verified", by: BY, created_at: MONDAY - 1.year)
    post = run_x("Beta Reactors said it designs small reactors.")
    assert_equal [ "drafted", company ], [ post.status, post.subject ], "Acme, re-verified this week but first approved a year ago, isn't new"
  end

  def live!
    SocialChannel.for("x").update!(mode: "live")
    ENV["SOCIAL_POSTING_ENABLED"] = "on"
  end

  teardown do
    ENV.delete("SOCIAL_POSTING_ENABLED")
    ENV.delete("SOCIAL_POST_COST_USD")
    SocialAgent.senders.delete("x")
  end

  DRAFT = "The Department of Energy said it awarded Acme Fission $1,404,253 to test fuel cladding.".freeze

  test "live sends once through the platform's sender, costed, and logs the permalink" do
    live!
    sent = nil
    SocialAgent.senders["x"] = ->(text, link) { sent = [ text, link ]; { id: "1", permalink: "https://x.com/i/web/status/1" } }
    post = run_x(DRAFT)
    assert_equal [ "posted", "https://x.com/i/web/status/1", SocialAgent.post_cost ], [ post.status, post.permalink, post.cost_usd ]
    assert_equal post.link, sent.last
  end

  test "Draft now never sends, even when the switch is Live (PM)" do
    live!
    SocialAgent.senders["x"] = ->(*) { flunk "sent" }
    post = SocialAgent.run("x", now: MONDAY, writer: FakeWriter.new(DRAFT), fetcher: OK_FETCHER.new(200), drafts_only: true)
    assert_equal "drafted", post.status
  end

  test "Live with sending off on the server only drafts" do
    SocialChannel.for("x").update!(mode: "live")
    SocialAgent.senders["x"] = ->(*) { flunk "never called" }
    assert_equal "drafted", run_x(DRAFT).status
  end

  test "a timeout is 'may have gone out' and never sent again; a definite error is logged; the cap stops it before the call" do
    live!
    SocialAgent.senders["x"] = ->(*) { raise SocialAgent::Uncertain, "timeout" }
    assert_equal "unknown", (post = run_x(DRAFT)).status
    assert_match "never resent", post.reason
    calls = 0
    SocialAgent.senders["x"] = ->(*) { calls += 1; { id: "2", permalink: "p" } }
    assert_nil SocialAgent.run("x", now: MONDAY + 1.day, writer: FakeWriter.new(DRAFT), fetcher: OK_FETCHER.new(200)), "the same item is never picked again"
    assert_equal 0, calls

    SocialPost.delete_all
    SocialAgent.senders["x"] = ->(*) { raise "X said 403" }
    assert_equal [ "failed", 0 ], run_x(DRAFT).then { |failed| [ failed.status, failed.cost_usd ] }

    SocialPost.delete_all
    ENV["SOCIAL_POST_COST_USD"] = "0.20"
    SocialPost.create!(platform: "x", status: "posted", subject: @company, cost_usd: SocialAgent.monthly_cap, created_at: MONDAY - 1.day)
    SocialAgent.senders["x"] = ->(*) { flunk "never called over the cap" }
    assert_match "cap", run_x(DRAFT).reason
  end

  test "two errors in a row switch the platform off and say so; a fact taken off since the pick isn't sent; placeholders stop" do
    live!
    SocialAgent.senders["x"] = ->(*) { raise "X said 403" }
    SocialPost.create!(platform: "x", status: "failed", subject: @company, created_at: MONDAY - 3.days)
    run_x(DRAFT)
    channel = SocialChannel.for("x")
    assert_equal [ "off", "2 sends in a row didn't go through" ], [ channel.mode, channel.paused_reason ]

    SocialPost.delete_all
    live!
    SocialAgent.senders["x"] = ->(*) { flunk "never sent" }
    @news.update_columns(verification_status: "unpublished")
    assert_match "no longer published", SocialAgent.send_post(SocialPost.new(platform: "x", subject: @news, text: DRAFT, link: "l"), now: MONDAY).reason

    assert_equal [ "it's empty or a placeholder" ], SocialAgent::Check.problems("[headline here]",
      SocialAgent::Item.new(subject: @news, kind: "news", facts: {}, source_url: nil, source_quote: "", path: "/", organization_ids: []), platform: "x")
  end

  test "a failed send uses up the day and its item (a rerun never sends it again); one platform failing doesn't stop the other" do
    live!
    SocialAgent.senders["x"] = ->(*) { raise "X said 403" }
    assert_equal "failed", run_x(DRAFT).status
    SocialAgent.senders["x"] = ->(*) { flunk "not again today" }
    assert_nil run_x(DRAFT)
    assert_nil SocialAgent.run("x", now: MONDAY + 1.day, writer: FakeWriter.new(DRAFT), fetcher: OK_FETCHER.new(200)), "nor its item tomorrow"

    calls = []
    original = SocialAgent.method(:run)
    SocialAgent.define_singleton_method(:run) { |platform, **| calls << platform; raise "model down" if platform == "x" }
    SocialPostJob.perform_now
    assert_equal %w[x linkedin], calls
  ensure
    SocialAgent.define_singleton_method(:run, original) if original
  end

  test "a model error stops that post, logged, and never the job; a company without evidence for its description isn't picked" do
    post = run_x(-> { raise DataQuality::OpenRouter::Client::RequestError, "model gone" })
    assert_equal [ "blocked", "couldn't write it: model gone" ], [ post.status, post.reason ]
    assert_equal "failed", CrawlRun.where(source_kind: "social_agent").last.status, "its usage has a run to count against"
  end

  test "mixed-case names are checked as whole words" do
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: {}, source_url: nil, path: "/", organization_ids: [],
      source_quote: "The eVinci microreactor produces 250 kW.")
    assert_empty SocialAgent::Check.problems("The eVinci microreactor produces 250 kW.", item, platform: "x")
  end

  test "a sentence's opening word and a possessive aren't new names; a made-up name still is (shadow day 20 Nov)" do
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: {}, source_url: nil, path: "/", organization_ids: [],
      source_quote: "Georgia Power filed its plan for Vogtle with state regulators.")
    assert_empty SocialAgent::Check.problems("Those plans came from Georgia Power. Georgia Power’s plan covers Vogtle.", item, platform: "x")
    assert_empty SocialAgent::Check.problems("Neither side gave a figure. Georgia Power filed its plan for Vogtle.", item, platform: "x"), "Neither and Either only open a sentence"
    assert_equal [ "the name \"Westinghouse\" isn't in the source" ],
      SocialAgent::Check.problems("Georgia Power's plan with Westinghouse covers Vogtle.", item, platform: "x")
    assert_equal [ "the name \"Two\" isn't in the source" ], SocialAgent::Check.problems("Two plans came from Georgia Power.", item, platform: "x"),
      "a spelled-out number is still checked (Copilot)"
  end

  test "a news item's publisher on its own site is a primary source; a look-alike isn't (DQ, shadow day)" do
    item = ->(url, publisher) { SocialAgent::Item.new(subject: @news, kind: "news", facts: { "publisher" => publisher }, source_url: url, path: "/",
      organization_ids: [], source_quote: "q") }
    assert SocialAgent::Rules.primary?(item.("https://deepisolation.com/press/otcqx", "Deep Isolation"))
    assert SocialAgent::Rules.primary?(item.("https://www.nuscalepower.com/news/1", "NuScale Power, Inc."))
    assert_not SocialAgent::Rules.primary?(item.("https://deepisolation-news.example/x", "Deep Isolation"))
    assert_not SocialAgent::Rules.primary?(item.("https://www.prnewswire.com/news/x", "Deep Isolation"))
    # An outlet or wire named as its own publisher is still not primary (DQ).
    assert_not SocialAgent::Rules.primary?(item.("https://www.prnewswire.com/news/x", "PR Newswire"))
    assert_not SocialAgent::Rules.primary?(item.("https://www.world-nuclear-news.org/articles/x", "World Nuclear News"))
    assert_not SocialAgent::Rules.primary?(item.("https://www.reuters.com/x", "Reuters"))
    assert_not SocialAgent::Rules.primary?(item.("https://www.ans.org/news/x", "ANS"))

    # A company the directory knows (pending too), named as the publisher, on its recorded website (PM).
    Organization.create!(name: "Borehole Energy", website: "https://www.boreholeco.example", verification_status: "pending")
    assert SocialAgent::Rules.primary?(item.("https://news.boreholeco.example/release", "Borehole Energy"))
    assert_not SocialAgent::Rules.primary?(item.("https://news.boreholeco.example/release", "Someone Else"))
  end

  test "a region or country is a place, not a person; a person's name still stops it (shadow day 20 Nov)" do
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: { "companies" => "Acme Fission" }, source_url: nil, path: "/",
      organization_ids: [], source_quote: "Acme Fission will work in Southeast Asia and South Korea.")
    assert_empty SocialAgent::Rules.people("Acme Fission will work in Southeast Asia and South Korea.", item)
    assert_equal [ "it may name a person (Jane Doe)" ], SocialAgent::Rules.people("Jane Doe leads Acme Fission in Southeast Asia.", item)
    assert_equal [ "it may name a person (Chad Jordan)" ], SocialAgent::Rules.people("Chad Jordan leads Acme Fission.", item),
      "country words alone never clear a name"
  end

  test "a person's name in the source is still stopped; a news date must be the item's own; elsewhere it must be in the source (PM)" do
    news = SocialAgent::Item.new(subject: @news, kind: "news", facts: { "date" => "19 November 2026" }, source_url: nil, path: "/",
      organization_ids: [], source_quote: "Acme Fission and SJ Group will work with Mary Lane on reactors.")
    assert_equal [ "it may name a person (Mary Lane)" ], SocialAgent::Rules.people("Acme Fission works with Mary Lane.", news),
      "a person's name stays stopped even when the source has it (GTM)"
    assert_empty SocialAgent::Rules.dates("On 19 November 2026, Acme Fission said so.", news)
    assert_equal [ "the date 18 November isn't the item's own (19 November 2026) or in the source" ], SocialAgent::Rules.dates("On November 18, Acme Fission said so.", news)
    link = SocialAgent::Item.new(subject: @news, kind: "link", facts: {}, source_url: nil, path: "/", organization_ids: [],
      source_quote: "The deal closed on 7 November 2023.")
    assert_empty SocialAgent::Rules.dates("It closed on 7 November 2023.", link)
    assert_equal [ "the date 8 November isn't in the source" ], SocialAgent::Rules.dates("It closed on 8 November.", link)
  end

  test "the picker skips news Data Quality said no to, and news only an off-topic feed gives (PM)" do
    assert SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.any? { |item| item.subject == @news }
    feed = Source.create!(url: "https://science.example/feed", source_kind: "nasa_nuclear_news", crawl_status: "ok")
    claim = Candidate.create!(source: feed, kind: "news_item", payload: {}, quote: "q", status: "merged", subject: @news)
    ENV["SOCIAL_SKIP_FEEDS"] = "nasa_nuclear_news"
    assert_not SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.any? { |item| item.subject == @news }, "only that feed gives it"
    ENV.delete("SOCIAL_SKIP_FEEDS")
    claim.update_columns(dq_recommendation: "reject")
    assert_not SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.any? { |item| item.subject == @news }, "DQ said no"
  ensure
    ENV.delete("SOCIAL_SKIP_FEEDS")
  end

  test "a news post's date must be on its source page, in its text or datePublished (DQ)" do
    assert SocialAgent::Rules.page_dated?("<p>November 19, 2026</p>", "19 November 2026")
    assert SocialAgent::Rules.page_dated?(%(<script type="application/ld+json">{"datePublished":"2026-11-19T10:00:00Z"}</script>), "19 November 2026")
    assert SocialAgent::Rules.page_dated?("<p>Posted 11/19/2026</p>", "19 November 2026")
    assert_not SocialAgent::Rules.page_dated?("<p>Pulsars, found faster.</p>", "19 November 2026")
    undated = Struct.new(:status) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: :ok, status: 200, body: "<p>No date here</p>",
      etag: nil, last_modified: nil, reason: "x", block_reference: nil, content_type: "text/html", truncated: false) }
    assert_nil run_x("The Department of Energy said it awarded Acme Fission $1,404,253 to test fuel cladding.", fetcher: undated.new(200)),
      "an item whose page lacks its date is skipped before drafting"
    assert_equal "no usable item (its date (12 November 2026) isn't on the source page)",
      CrawlRun.where(source_kind: SocialAgent::STOPPED).order(:id).last.stats["stopped"]
  end

  test "a post never says what its source doesn't, and keeps the source's qualifier on a deal (GTM)" do
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: {}, source_url: nil, path: "/", organization_ids: [],
      source_quote: "Acme Fission signed a non-binding memorandum of understanding with SJ Group.")
    assert_equal [ "it says \"no further details\", which its source doesn't", "it leaves out the source's qualifier (MOU)",
      "it leaves out the source's qualifier (non-binding)" ],
      SocialAgent::Rules.qualifiers("Acme Fission agreed to work with SJ Group; the announcement provides no further details.", item)
    assert_empty SocialAgent::Rules.qualifiers("Acme Fission signed a non-binding MOU with SJ Group.", item)
  end

  # Today's two shadow drafts (20 Nov), as written.
  PULSAR_TITLE = "NASA Fermi data helps team develop faster pulsar search method".freeze
  NANO_SOURCE = "NANO Nuclear Energy signed a Memorandum of Understanding (MOU) with Surbana Jurong Infrastructure Pte. Ltd., an " \
    "affiliate of SJ Group, to advance knowledge exchange and capability building in advanced nuclear energy across Southeast Asia. " \
    "It establishes a non-binding framework for cooperation.".freeze
  NANO_DRAFT = "On 19 November 2026, NANO Nuclear Energy and SJ Group established a collaboration to advance knowledge exchange and " \
    "capability building in advanced nuclear energy across Southeast Asia, NANO Nuclear Energy said.\n\nThe stated focus is knowledge " \
    "exchange and capability building, with advanced nuclear energy as the subject and Southeast Asia as the region. The announcement " \
    "names the two organizations but provides no further details about the collaboration.".freeze

  test "today's drafts: a pulsar story is never picked; the NANO post is stopped for its absence claim, missing qualifiers and repetition, not for a person" do
    @news.update_columns(title: PULSAR_TITLE, headline: nil, summary: "Open data from Fermi helped find pulsars faster.")
    assert_not SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.any? { |item| item.subject == @news }, "not nuclear (Founder, GTM)"

    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: { "companies" => "NANO Nuclear Energy" }, source_url: nil, path: "/",
      organization_ids: [], source_quote: NANO_SOURCE)
    assert_empty SocialAgent::Rules.people(NANO_DRAFT, item), "Southeast Asia is a place"
    problems = SocialAgent::Rules.qualifiers(NANO_DRAFT, item)
    assert_includes problems, "it says \"no further details\", which its source doesn't"
    assert_includes problems, "it leaves out the source's qualifier (MOU)"
    assert SocialAgent::Rules.repeats?(NANO_DRAFT), "the second paragraph restates the first"
    assert_includes problems, "it calls it a collaboration, which its source doesn't", "DQ: a signed MOU isn't 'a collaboration'"
    assert_includes SocialAgent::Rules.qualifiers("They did not say when it starts.", item), "it says \"did not say\", which its source doesn't"
    assert_not SocialAgent::Rules.repeats?("Acme Fission won a DOE award for fuel cladding. The work starts in Idaho next spring with two partners.")
  end

  test "a rehearsal drafts and checks every candidate and the fixed cases, saves no post and uses no day's slot (PM)" do
    SocialChannel.for("x").update!(mode: "drafts")
    results = SocialAgent::Rehearsal.new(per_platform: 5, now: MONDAY, writer: FakeWriter.new(DRAFT), fetcher: OK_FETCHER.new(200)).run
    assert_equal 0, SocialPost.count, "nothing saved"
    assert_equal %w[linkedin x], results.map(&:platform).uniq.sort
    assert(results.any? { |row| row.label.start_with?("fixture: #35") }, "today's fixed cases are in")
    assert(results.any? { |row| row.kind == "news" && row.passed? }, "the real news item drafts and passes")
    report = SocialAgent::Rehearsal.report(results)
    assert_match(/## X: \d+ of \d+ passed/, report)
    assert_not_nil run_x(DRAFT), "the day's slot is still free"
  end

  test "a person's name inside a company's name is still a person; the company's whole name isn't (DQ)" do
    Organization.create!(name: "Mary Lane Engineering", verification_status: "verified", verified_by: BY)
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: {}, source_url: nil, path: "/", organization_ids: [], source_quote: "q")
    assert_equal [ "it may name a person (Mary Lane)" ], SocialAgent::Rules.people("Mary Lane leads Acme Fission.", item)
    assert_empty SocialAgent::Rules.people("Mary Lane Engineering works with Acme Fission.", item)
  end

  test "the source page's own qualifier counts too: an MOU only the page body names must be in the post (rehearsal)" do
    page = Struct.new(:status) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: :ok, status: 200,
      body: "<p>November 19, 2026</p><p>NANO signed a non-binding MOU with Surbana Jurong Infrastructure Pte. Ltd.</p>", etag: nil,
      last_modified: nil, reason: "x", block_reference: nil, content_type: "text/html", truncated: false) }
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: { "date" => "19 November 2026" }, source_url: "https://nanonuclearenergy.com/x",
      path: "/", organization_ids: [], source_quote: "NANO Nuclear and SJ Group establish Southeast Asia collaboration")
    problems = SocialAgent::Rules.source_problems(item.source_url, page.new(200), item:, text: "NANO Nuclear and SJ Group set up a collaboration.")
    assert_includes problems, "it leaves out the source's qualifier (MOU)"
    assert_empty SocialAgent::Rules.people("NANO Nuclear signed with Surbana Jurong Infrastructure Pte. Ltd.", item), "a legal name isn't a person"
  end

  test "a stopped draft gets one revision with what stopped it, then every check again (rehearsal)" do
    drafts = [ "Acme Fission won 2 DOE awards.", DRAFT ]
    seen = []
    writer = FakeWriter.new(-> { drafts.shift })
    writer.define_singleton_method(:draft) { |_item, platform:, crawl_run: nil, feedback: nil, previous: nil| seen << feedback; drafts.shift }
    post = SocialAgent.run("x", now: MONDAY, writer:, fetcher: OK_FETCHER.new(200))
    assert_equal "drafted", post.status
    assert_equal [ nil, "the number 2 isn't in the source" ], seen
  end

  test "a sensitive word in passing deep in a page isn't its subject; in its opening it is (rehearsal)" do
    page = ->(body) { Struct.new(:body) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: :ok, status: 200, body:, etag: nil,
      last_modified: nil, reason: "x", block_reference: nil, content_type: "text/html", truncated: false) }.new(body) }
    filler = "<p>#{'The reactor design moves ahead with its partners and suppliers. ' * 20}</p>"
    assert_empty SocialAgent::Rules.source_problems("https://x.example", page.("<article>#{filler}<p>It holds up beyond any credible accident scenario.</p></article>"))
    assert_equal [ "its source page touches a sensitive topic (accident)" ],
      SocialAgent::Rules.source_problems("https://x.example", page.("<article><p>An accident at the plant injured two workers.</p>#{filler}</article>"))
  end

  test "Copilot on #842: whole country names, years in dates, whole date forms, each absence phrase, quantities, spaced keywords" do
    item = SocialAgent::Item.new(subject: @news, kind: "news", facts: { "date" => "19 November 2026" }, source_url: nil, path: "/",
      organization_ids: [], source_quote: "Acme Fission signed in 2023. The amount was not disclosed.")
    assert_equal [ "it may name a person (Asia Cook)" ], SocialAgent::Rules.people("Asia Cook leads Acme Fission.", item)
    assert_empty SocialAgent::Rules.people("Acme Fission works in South Korea and the United Kingdom.", item)
    assert_equal [ "the date 19 November isn't the item's own (19 November 2026) or in the source" ],
      SocialAgent::Rules.dates("On 19 November 2023, Acme Fission said so.", item)
    assert_empty SocialAgent::Rules.dates("On 19 November 2026, Acme Fission said so.", item)
    assert_not SocialAgent::Rules.page_dated?("<p>19 November 2026</p>", "9 November 2026")
    assert_equal [ "it says \"no further details\", which its source doesn't" ],
      SocialAgent::Rules.qualifiers("The amount was not disclosed; there are no further details.", item).grep(/says/)
    assert_not SocialAgent::Rules.repeats?("The reactor produces 50 MW of electricity at full power. It produces 100 MW of heat at full power.")
    assert_match SocialAgent::Picker::NUCLEAR, "Holtec expands spent fuel storage"
  end

  test "a draft still stopped after the last revision stays blocked with its reason; a revision gets only the reason, no new facts (DQ)" do
    calls = []
    writer = FakeWriter.new("x")
    writer.define_singleton_method(:draft) do |item, platform:, crawl_run: nil, feedback: nil, previous: nil|
      calls << [ item.facts, feedback ]
      "Acme Fission won 2 DOE awards."
    end
    post = SocialAgent.run("x", now: MONDAY, writer:, fetcher: OK_FETCHER.new(200))
    assert_equal [ "blocked", "the number 2 isn't in the source" ], [ post.status, post.reason ]
    assert_equal 3, calls.size, "the first draft and two revisions"
    assert_equal 1, calls.map(&:first).uniq.size, "every revision gets the same facts, nothing new"
    assert_equal [ nil, "the number 2 isn't in the source", "the number 2 isn't in the source" ], calls.map(&:last)
    assert_not SocialPost.where(status: SocialPost::SENT).exists?, "never posted"
  end

  test "a month's post count is a backstop" do
    live!
    ENV["SOCIAL_MONTHLY_MAX"] = "1"
    SocialPost.create!(platform: "x", status: "posted", subject: @company, created_at: MONDAY - 3.days)
    SocialAgent.senders["x"] = ->(*) { flunk "never called over the backstop" }
    assert_match "this month's 1 posts are done", run_x(DRAFT).reason
  ensure
    ENV.delete("SOCIAL_MONTHLY_MAX")
  end

  test "one send per item and platform, enforced by the database" do
    SocialPost.create!(platform: "x", status: "unknown", subject: @news)
    assert_raises(ActiveRecord::RecordNotUnique) { SocialPost.create!(platform: "x", status: "sending", subject: @news) }
  end

  # A publisher that schedules, cancels and reports, as Buffer does.
  class FakePublisher
    attr_reader :cancelled
    attr_accessor :states
    def initialize = (@cancelled, @states = [], {})
    def call(_platform, _text, _link) = { id: "b1", due_at: MONDAY + 15.minutes }
    def cancel(id) = @cancelled << id
    def status(id) = states.fetch(id, { status: "scheduled" })
  end

  test "through a scheduling publisher: queued, then read back as posted with its link; switching off takes queued posts back" do
    live!
    publisher = FakePublisher.new
    SocialAgent.define_singleton_method(:publisher) { publisher }
    SocialAgent.instance_variable_set(:@senders, nil)
    post = run_x(DRAFT)
    assert_equal [ "queued", "b1", MONDAY + 15.minutes ], [ post.status, post.external_id, post.posted_at ]

    travel_to(MONDAY - 1.minute) do
      SocialChannel.for("x").update!(mode: "drafts")
      SocialAgent.sync(publisher:)
    end
    assert_equal [ "cancelled", [ "b1" ] ], [ post.reload.status, publisher.cancelled ]

    post.update!(status: "queued")
    SocialChannel.for("x").update!(mode: "live")
    publisher.states["b1"] = { status: "sent", link: "https://x.com/NuclearDir/status/7" }
    travel_to(MONDAY + 20.minutes) { SocialAgent.sync(publisher:) }
    assert_equal [ "posted", "https://x.com/NuclearDir/status/7" ], [ post.reload.status, post.permalink ]
  ensure
    SocialAgent.singleton_class.send(:remove_method, :publisher)
    SocialAgent.define_singleton_method(:publisher) { SocialAgent::Buffer.new }
    SocialAgent.instance_variable_set(:@senders, nil)
  end

  # Copilot's six findings on #842, each with its regression.
  def rules_item(kind: "news", facts: {}, quote: "")
    SocialAgent::Item.new(subject: @news, kind:, facts:, source_url: nil, source_quote: quote, path: "/", organization_ids: [])
  end

  test "a country is its whole name: 'Asia Cook' is a person, 'South Korea' and 'Southeast Asia' are places" do
    assert SocialAgent::Rules.place?(%w[Southeast Asia])
    assert SocialAgent::Rules.place?(%w[South Korea])
    assert SocialAgent::Rules.place?(%w[South Africa])
    assert SocialAgent::Rules.place?(%w[Middle East])
    assert SocialAgent::Rules.place?(%w[Asia Cook Islands]), "the whole name counts"
    assert_not SocialAgent::Rules.place?(%w[Asia Cook]), "Cook alone isn't a country"
    assert_not SocialAgent::Rules.place?(%w[Chad Jordan]), "a country alone never clears a run"
  end

  test "the nuclear gate sees 'spent fuel' and 'fuel cycle' as phrases, and not 'spentfuel'" do
    assert_match SocialAgent::Picker::NUCLEAR, "Holtec expands spent fuel storage"
    assert_match SocialAgent::Picker::NUCLEAR, "A new fuel cycle report"
    assert_no_match SocialAgent::Picker::NUCLEAR, "Holtec expands spentfuel storage"
    assert_no_match SocialAgent::Picker::NUCLEAR, "NASA bone-marrow chip tests how space radiation and isotopes affect astronauts", "a space-radiation or imaging story isn't about the industry"
    assert_match SocialAgent::Picker::NUCLEAR, "Commonwealth Fusion Systems fusion energy plant"
  end

  test "a date with a year must be the item's year: 19 November 2023 isn't the 2026 item's date" do
    item = rules_item(facts: { "date" => "2026-11-19" }, quote: "Announced on 19 November 2026. The earlier plan dates from 2023.")
    assert_empty SocialAgent::Rules.dates("On 19 November 2026 Acme signed.", item)
    assert_empty SocialAgent::Rules.dates("On 19 November Acme signed.", item), "no year written: the item's day and month are enough"
    assert_equal 1, SocialAgent::Rules.dates("On 19 November 2023 Acme signed.", item).size
    other = rules_item(kind: "link", quote: "The closing is on 19 November 2026.")
    assert_empty SocialAgent::Rules.dates("Closing is on 19 November 2026.", other)
    assert_equal 1, SocialAgent::Rules.dates("Closing is on 19 November 2023.", other).size, "a non-news post's year is the source's too"
  end

  test "a source stating 19 November 2026 doesn't state 9 November 2026" do
    assert SocialAgent::Rules.page_dated?("<p>Published 19 November 2026</p>", "2026-11-19")
    assert_not SocialAgent::Rules.page_dated?("<p>Published 19 November 2026</p>", "2026-11-09")
    assert_not SocialAgent::Rules.page_dated?("<p>Published November 19, 2026</p>", "2026-11-09")
    other = rules_item(kind: "link", quote: "Signed on 19 November 2026.")
    assert_equal 1, SocialAgent::Rules.dates("Signed on 9 November.", other).size, "9 isn't 19"
  end

  test "each absence phrase must be the source's own: 'not disclosed' doesn't clear 'no further details'" do
    item = rules_item(quote: "The amount was not disclosed. The agreement covers fuel supply and a 2027 delivery.")
    problems = SocialAgent::Rules.qualifiers("The amount was not disclosed, with no further details.", item)
    assert_includes problems, "it says \"no further details\", which its source doesn't"
    assert_not problems.any? { |problem| problem.include?("not disclosed") }, "the source says that one"
  end

  test "sentences giving different quantities aren't a repeat; the same thing said twice still is" do
    assert_not SocialAgent::Rules.repeats?("The reactor produces 50 MW of electricity at full power. It produces 100 MW of heat at full power.")
    assert SocialAgent::Rules.repeats?("The reactor produces 50 MW of electricity at full power. At full power the reactor produces 50 MW of electricity.")
  end

  test "the writer lets a legal suffix go, and the voice check doesn't fail the nits rehearsal rounds 1-11 found" do
    seen = []
    client = Object.new
    client.define_singleton_method(:structured) do |messages:, **|
      seen << messages.first[:content]
      Struct.new(:data).new({ "text" => "x" * 30, "pass" => true, "reason" => "" })
    end
    writer = SocialAgent::Writer.new(client:)
    item = SocialAgent::Item.new(subject: nil, kind: "news", facts: { "headline" => "Acme signs an MOU" }, source_url: nil, source_quote: "q", path: "/", organization_ids: [])
    writer.draft(item, platform: "x")
    writer.voice_ok?("Acme signed a non-binding MOU.", item)

    assert_match(/legal ending\s+such as Inc\., Ltd\. or Pte\. Ltd\./, seen.first, "the writer may leave a legal ending off")
    assert_match(/Do not fail a post for these/, seen.last)
    assert_match(/non-binding MOU/, seen.last)
    assert_match(/Fail it when it reverses who did what for whom, or changes what the source says/, seen.last, "real changes still fail")
    assert_match(/A word that is in the post\s+\("nearly"/, seen.last, "a qualifier that is present isn't missing (GTM, 20 Nov)")
    assert_match(/future wording for what the source says will happen/, seen.last)
    assert_match(/Quote the post's own offending words/, seen.last)
    assert_match(/"said that" is not a required template/, seen.last)
    assert_match(/Say what a deal or event covers/, seen.first)
    assert_match(/Keep who did what for whom/, seen.first, "Founder: STS supported ORS, not the reverse")
    assert_match(/reverses who did what for whom/, seen.last)
  end

  test "the consistency table shows each item's PASS/BLOCK history, flags the flaky and marks only 3 straight passes ready (PM, 20 Nov)" do
    row = ->(url, ok) { { "platform" => "x", "label" => "news #{url}", "problems" => ok ? [] : [ "voice check" ], "source_url" => url } }
    Dir.mktmpdir do |dir|
      [ [ true, false, true ], [ true, true, true ], [ true, true, true ], [ false, true, true ] ].each_with_index do |states, round|
        File.write(File.join(dir, "round-#{round + 1}.json"), JSON.generate(states.each_with_index.map { |ok, index| row.("https://a.example/#{index}", ok) }))
      end
      table = SocialAgent::Rehearsal.consistency(Dir[File.join(dir, "*.json")])

      assert_includes table, "| x | https://a.example/0 | PPPB | flaky |  |"
      assert_includes table, "| x | https://a.example/1 | BPPP | flaky | ready |", "passed its last three rounds, but a block earlier"
      assert_includes table, "| x | https://a.example/2 | PPPP |  | ready |"
      assert_includes table, "Items ready (3 of 3 runs, fixtures excluded): 2"
    end
  end

  test "every post links our own page with utm_source x or linkedin and the page's slug, and says its source in words (Tosin, 20 Nov)" do
    item = rules_item(kind: "news", quote: "Acme said it signed.")
    item = item.with(path: "/companies/acme-fission")
    assert_equal "https://nuclear-directory.org/companies/acme-fission?utm_source=x&utm_medium=social&utm_campaign=acme-fission", SocialAgent.link(item, "x")
    assert_equal "https://nuclear-directory.org/companies/acme-fission?utm_source=linkedin&utm_medium=social&utm_campaign=acme-fission", SocialAgent.link(item, "linkedin")
    assert_not_includes SocialAgent.link(item, "x"), "energy.gov", "never the source's address"

    assert SocialAgent::Rules.attributed?("The award was listed in a Federal Register notice.")
    assert_not SocialAgent::Rules.attributed?("Acme Fission won a DOE award.")
  end

  test "a company's own site is a primary source; a wire or outlet never is, whoever it covers (PM, 20 Nov)" do
    gle = Organization.create!(name: "Global Laser Enrichment", slug: "global-laser-enrichment", website: "https://www.gle-us.com",
      verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    on = ->(url) { rules_item(facts: { "publisher" => "Global Laser Enrichment" }).with(source_url: url, organization_ids: [ gle.id ]) }

    assert SocialAgent::Rules.primary?(on.("https://www.gle-us.com/wp-content/uploads/2026/10/NRC-Issues-GLE-FEIS.pdf")), "GLE's own site"
    assert_not SocialAgent::Rules.primary?(on.("https://www.prnewswire.com/news-releases/gle-feis.html")), "a wire"
    assert_not SocialAgent::Rules.primary?(on.("https://www.globenewswire.com/news-release/gle"))
    assert_not SocialAgent::Rules.primary?(on.("https://www.businesswire.com/news/home/gle"))
  end

  test "GTM and DQ round 17: a government document is its agency's, a dated event is past tense, a superlative is attributed, the report shows our link" do
    nrc = rules_item(facts: { "companies" => "Leapfrog Nuclear", "date" => "2026-10-19" }, quote: "NRC assigned project number 99902187.").with(source_url: "https://www.nrc.gov/docs/ML2628/ML26281A396.pdf")
    wrong = SocialAgent::Rules.speaker_problems("Leapfrog Nuclear said on 19 October 2026 that NRC assigned it project number 99902187.", nrc)
    assert_equal 1, wrong.size
    assert_match(/but its source is a government document/, wrong.first)
    assert_empty SocialAgent::Rules.speaker_problems("The NRC said on 19 October 2026 it assigned Leapfrog Nuclear project number 99902187.", nrc), "the agency speaks"
    nasa = rules_item(facts: { "companies" => "NASA", "publisher" => "NASA" }).with(source_url: "https://science.nasa.gov/centers-and-facilities/glenn/x")
    assert_empty SocialAgent::Rules.speaker_problems("NASA said on 17 November 2026 its student challenge kicked off.", nasa), "the agency speaking about itself"
    assert_empty SocialAgent::Rules.people("Seadrift Operations is the site.", rules_item(quote: "Dow's Seadrift Operations site in Texas.")), "Operations makes it a facility, not a person"
    company_page = rules_item(facts: { "companies" => "Leapfrog Nuclear" }).with(source_url: "https://leapfrog.example/news")
    assert_empty SocialAgent::Rules.speaker_problems("Leapfrog Nuclear said it signed.", company_page), "a company's own release is its own"

    assert_equal 1, SocialAgent::Rules.tense_problems("BWXT said on 27 October 2026 it signs a TRISO fuel agreement with Antares.").size
    assert_empty SocialAgent::Rules.tense_problems("DOE said on 18 November 2026 the work enters a new phase."), "'enters' is too ambiguous to block on (round 21)"
    assert_empty SocialAgent::Rules.tense_problems("BWXT said on 27 October 2026 it signed a TRISO fuel agreement with Antares.")
    assert_empty SocialAgent::Rules.tense_problems("BWXT signs agreements with fuel makers."), "no date, no tense rule"

    assert_equal 1, SocialAgent::Rules.unattributed_superlatives("The Long Mott project is the first advanced facility at a US industrial site.").size
    assert_empty SocialAgent::Rules.unattributed_superlatives("DOE calls the Long Mott project the first advanced facility at a US industrial site.")
    assert_empty SocialAgent::Rules.unattributed_superlatives("Dow said it is the largest site it operates.")

    row = SocialAgent::Rehearsal::Result.new(platform: "x", label: "news", kind: "news", text: "DOE said on 12 November it awarded Acme.", problems: [], source_url: "https://www.energy.gov/a",
      date: "2026-11-12", quote: "q", link: "https://nuclear-directory.org/companies/acme-fission?utm_source=x&utm_medium=social&utm_campaign=acme-fission")
    assert_includes SocialAgent::Rehearsal.report([ row ]), "our page (the post's link): https://nuclear-directory.org/companies/acme-fission?utm_source=x"
  end

  test "a regulator's act keeps the source's own verb: 'authorized' isn't 'approved' (DQ, round 17)" do
    item = rules_item(quote: "DOE approved a construction permit for the Long Mott project.")
    assert_equal 1, SocialAgent::Rules.act_problems("DOE authorized a construction permit for Long Mott.", item).size
    assert_empty SocialAgent::Rules.act_problems("DOE approved a construction permit for Long Mott.", item)
    assert_empty SocialAgent::Rules.act_problems("Dow and X-energy received a construction permit.", item), "no act verb, nothing to check"
  end

  test "an unsupported negative can't ride on 'Neither': it is an absence claim like 'no further details' (DQ, #868)" do
    item = rules_item(quote: "Acme Fission signed a fuel supply agreement with Westinghouse.")
    [ "Neither side gave a figure.", "Acme Fission declined to give a price.", "Acme did not give a date.", "Westinghouse has not said when it starts." ].each do |sentence|
      assert SocialAgent::Rules.qualifiers(sentence, item).any? { |problem| problem.start_with?("it says") }, sentence
    end
    said = rules_item(quote: "Neither side gave a figure for the agreement.")
    assert_empty SocialAgent::Rules.qualifiers("Neither side gave a figure.", said).select { |problem| problem.start_with?("it says") }, "when the source says it"
  end

  test "the page reader reads the real article (a thin <article> or a list of stories) and never a PDF's bytes (GTM, round 17)" do
    body_text = "BWXT announces a multi-year commercial agreement with Antares for TRISO fuel production. " * 12
    thin = "<html><body><nav>Menu</nav><article><h1>BWXT signs TRISO agreement</h1></article><div class='body'><p>#{body_text}</p></div><footer>Contact</footer></body></html>"
    text = SocialAgent::Rules.article_text(thin)
    assert_includes text, "multi-year commercial agreement", "the body beside a thin article"
    assert_not_includes text, "Menu"
    assert_not_includes text, "Contact"

    list = "<html><body><main><article><h2>Short story</h2><p>Brief.</p></article><article><p>#{body_text}</p></article></main></body></html>"
    assert_includes SocialAgent::Rules.article_text(list), "TRISO fuel production", "the longest article of a list"

    pdf = Struct.new(:content_type, :body)
    assert SocialAgent::Rules.pdf?(pdf.new("application/pdf", "x"))
    assert SocialAgent::Rules.pdf?(pdf.new("text/html", "%PDF-1.4 \x00\x01"))
    assert_not SocialAgent::Rules.pdf?(pdf.new("text/html", "<html></html>"))
    pdf_fetcher = Struct.new(:ignored) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: :ok, status: 200, body: "%PDF-1.4 binary", etag: nil, last_modified: nil, reason: "x", block_reference: nil, content_type: "application/pdf", truncated: false) }
    assert_equal [ "its source is a PDF, which the agent can't read yet: no grounding for a post" ], SocialAgent::Rules.source_problems("https://www.nrc.gov/a.pdf", pdf_fetcher.new)
  end

  test "the consistency table reads rounds in natural order (round-10 after round-2) and keeps a fixture apart from a live item with the same source (Copilot, #868)" do
    row = ->(label, url, ok) { { "platform" => "x", "label" => label, "problems" => ok ? [] : [ "voice check" ], "source_url" => url } }
    Dir.mktmpdir do |dir|
      # An item that passes rounds 1-9 and fails 10 and 11 is not ready; a plain sort would put 10 and 11 before 2.
      (1..11).each do |round|
        File.write(File.join(dir, "round-#{round}.json"), JSON.generate([
          row.("news a", "https://a.example/late-failure", round < 10),
          row.("fixture: NANO MOU", "https://a.example/mou", true),
          row.("news NANO", "https://a.example/mou", round == 11 ? false : true)
        ]))
      end
      table = SocialAgent::Rehearsal.consistency(Dir[File.join(dir, "*.json")])

      assert_includes table, "| x | https://a.example/late-failure | PPPPPPPPPBB | flaky |  |", "its history reads in round order, so it isn't ready"
      assert_includes table, "| x | fixture: NANO MOU | PPPPPPPPPPP |  | ready |", "the fixture is its own row"
      assert_includes table, "| x | https://a.example/mou | PPPPPPPPPPB | flaky |  |", "the live item's block isn't hidden by the fixture"
      assert_includes table, "Items ready (3 of 3 runs, fixtures excluded): 0"
    end
  end

  # 'Meet a company' (#883).
  def spotlight_company(name, slug, complete: true, website: true, role: "reactor_vendor")
    company = Organization.create!(name:, slug:, verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year, domain: ("#{slug}.example" if website),
      website: ("https://#{slug}.example" if website), description: "#{name} designs small modular reactors.", hq_city: ("Austin" if complete), hq_state: ("Texas" if complete))
    page = Source.create!(url: "https://#{slug}.example/about", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: company, source: page, quote: "#{name} designs small modular reactors.", found_by: "human", fields: %w[description])
    Evidence.create!(subject: company, source: page, quote: "Headquartered in Austin, Texas.", found_by: "human", fields: %w[hq_city hq_state]) if complete
    if complete
      kind = Role.find_or_create_by!(key: role) { |row| row.name = role.humanize }
      held = OrganizationRole.create!(organization: company, role: kind, verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
      Evidence.create!(subject: held, source: page, quote: "What we do.", found_by: "human")
      tech = Technology.create!(key: "smr_#{slug.tr("-", "_")}", name: "Small modular reactor")
      link = OrganizationTechnology.create!(organization: company, technology: tech, verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
      Evidence.create!(subject: link, source: page, quote: "Our SMR design.", found_by: "human")
      other = Organization.create!(name: "#{name} Partner", slug: "#{slug}-partner", verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
      deal = Relationship.create!(from_organization: company, to_organization: other, relationship_type: "supplies", description: "Announced plan (Oct 2023): #{name} to provide 24 modules to #{name} Partner", started_on: Date.new(2023, 10, 5), verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
      Evidence.create!(subject: deal, source: page, quote: "#{name} supplies #{name} Partner.", found_by: "human")
    end
    company
  end

  test "spotlights: complete sourced profiles first, from the company's own site, none repeated within eight weeks, none without a website (#883)" do
    ENV.delete("SOCIAL_POST_KINDS")
    thin = spotlight_company("Thin Reactors", "thin-reactors", complete: false)
    full = spotlight_company("Full Reactors", "full-reactors")
    spotlight_company("No Site", "no-site", website: false)
    items = SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates
    assert_equal [ "spotlight" ], items.map(&:kind).uniq
    assert_equal [ full ], items.map(&:subject), "only a complete profile (role, website, description, headquarters, a link); no website or a thin page isn't a candidate"
    item = items.first
    assert_equal "https://full-reactors.example/about", item.source_url
    assert_match "Austin, Texas", item.facts["headquarters"]
    assert_nil item.facts["works on"], "no roles or technology lines (DQ)"
    assert_match "Announced plan (Oct 2023): Full Reactors to provide 24 modules to Full Reactors Partner (October 2023) [source: a page on full-reactors.example]".sub("a page on full-reactors.example", "the company's own website"), item.facts["records of its links"], "a link in its record's words, dated and sourced, never a bare verb"
    assert_equal "the company's own website", item.facts["description comes from"]
    assert_equal "the company's own website", item.facts["headquarters comes from"]
    assert SocialAgent::Rules.primary?(item), "the company's own site is a primary source"

    SocialPost.create!(platform: "linkedin", status: "posted", subject: full, text: "Meet Full Reactors.", created_at: MONDAY - 7.weeks)
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates, "spotlighted within eight weeks"
    SocialPost.update_all(created_at: MONDAY - 9.weeks)
    assert_includes SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.map(&:subject), full
  end

  test "a spotlight post links our company page with tracking and passes the same checks" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    post = run_x("Meet Full Reactors: according to its website, it designs small modular reactors. It is based in Austin, Texas. Per the directory's records, in October 2023 it announced a plan to provide 24 modules to Full Reactors Partner.")
    assert_equal "drafted", post.status, post.reason
    assert_equal full, post.subject
    assert_equal "https://nuclear-directory.org/companies/full-reactors?utm_source=x&utm_medium=social&utm_campaign=full-reactors", post.link
    assert_equal "https://full-reactors.example/about", post.source_url
    SocialPost.delete_all
    capital = run_x("Meet Full Reactors: According to its website, it designs small modular reactors. Nuclear Directory lists Full Reactors as supplying Full Reactors Partner.")
    assert_equal "drafted", capital.status, capital.reason
    SocialPost.delete_all
    assert_match "isn't in the source", run_x("Meet Full Reactors: according to its website, it designs small modular reactors and employs 400 people.").reason
  end

  test "news posts stay available as an extra when SOCIAL_POST_KINDS lists them" do
    ENV["SOCIAL_POST_KINDS"] = "spotlight,news"
    assert_includes SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.map(&:kind), "news"
    ENV.delete("SOCIAL_POST_KINDS")
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.select { |item| item.kind == "news" }, "spotlights only by default"
  end

  test "spotlights skip an agency, lab or university, and take the page its description rests on when that is the company's own site (#883)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    spotlight_company("Fed Agency", "fed-agency", role: "government_agency")
    spotlight_company("Some Fund", "some-fund", role: "venture_capital")
    items = SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates
    assert_equal [ full ], items.map(&:subject), "an agency isn't a company"
    assert_equal "https://full-reactors.example/about", items.first.source_url, "the own-site page its description rests on"
  end

  test "spotlights skip a company with an open candidate or a pending take-off, and put GTM's verified-account companies first (DQ, #883)" do
    ENV.delete("SOCIAL_POST_KINDS")
    a = spotlight_company("Alpha Reactors", "alpha-reactors")
    b = spotlight_company("Beta Reactors", "beta-reactors")
    c = spotlight_company("Gamma Reactors", "gamma-reactors")
    original = SocialAgent::Picker.instance_variable_get(:@tags)
    SocialAgent::Picker.instance_variable_set(:@tags, { "gamma-reactors" => { "x" => "@gamma_reactors", "linkedin" => "Gamma Reactors" } })
    begin
      order = SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates
      assert_equal c, order.first.subject, "verified accounts first"
      assert_equal "@gamma_reactors", order.first.facts["x_handle"], "its handle on X"
      assert_nil SocialAgent::Picker.new(platform: "linkedin", now: MONDAY).candidates.first.facts["x_handle"], "no tag on LinkedIn"
      TakeoffProposal.create!(subject_type: "Organization", subject_id: a.id, batch: "t", reason: "wrong", proposed_by: "dq", status: "pending")
      Candidate.create!(source: Source.first, kind: "organization", subject_type: "Organization", subject_id: b.id, status: "new", payload: {})
      assert_equal [ c ], SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.map(&:subject)

      post = run_x("Meet Gamma Reactors (@gamma_reactors): according to its website, it designs small modular reactors. It is based in Austin, Texas, and supplies Gamma Reactors Partner.")
      assert_equal "drafted", post.status, post.reason
      SocialPost.delete_all
      assert_match "which isn't this company's verified handle", run_x("Meet Gamma Reactors (@someone_else): according to its website, it designs small modular reactors.").reason
    ensure
      SocialAgent::Picker.instance_variable_set(:@tags, original)
    end
  end

  test "the verified-accounts list only holds handles, per slug (GTM's list)" do
    assert SocialAgent::Picker.tags.size > 20
    assert_equal "@terrapower", SocialAgent::Picker.tags.dig("terrapower", "x")
    assert SocialAgent::Picker.tags.values.all? { |row| row["x"].to_s.match?(/\A@\w+\z/) || row["x"].nil? }
  end

  test "a supplies link whose description isn't about supply is left out, and X tells one link at most (DQ, #884)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    lease = Relationship.where(from_organization: full).first
    lease.update!(description: "Collaboration and site lease at the ARC campus")
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates, "its only link isn't a supply link"
    lease.update!(description: "Announced plan (Oct 2023): to provide 24 modules")
    other = Organization.create!(name: "Third Co", slug: "third-co", verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
    second = Relationship.create!(from_organization: full, to_organization: other, relationship_type: "invests_in", description: "Term sheet (Sept 2026) for up to $100 million", verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
    Evidence.create!(subject: second, source: Source.first, quote: "Term sheet.", found_by: "human")
    assert_equal 1, SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.first.facts["records of its links"].split("; ").size
    assert_equal 2, SocialAgent::Picker.new(platform: "linkedin", now: MONDAY).candidates.first.facts["records of its links"].split("; ").size
  end

  test "'per its website' / 'per DOE' name the source in words (spotlights, #883)" do
    assert SocialAgent::Rules.attributed?("Meet Acme: it designs reactors, per its website.")
    assert SocialAgent::Rules.attributed?("It received a loan, per USAspending.gov.")
    assert_not SocialAgent::Rules.attributed?("Meet Acme: it designs reactors.")
    assert_not SocialAgent::Rules.attributed?("Meet Acme: it designs 3 reactors per year.")
  end

  test "'the first phase' is an order, not a claim to be first; 'the first SMR design' still is" do
    assert_empty SocialAgent::Rules.unattributed_superlatives("Amazon has the right to buy electricity from the first phase.")
    assert_empty SocialAgent::Rules.unattributed_superlatives("It builds the first two units.")
    assert_not_empty SocialAgent::Rules.unattributed_superlatives("It is the first SMR design approved by the NRC.")
  end

  test "spotlight facts: a funds link that is a loan is told in the record's words, and a description from a press release is never 'its website' (DQ, #884)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    Relationship.where(from_organization: full).update_all(relationship_type: "funds", description: "Loan of $1.52 billion under the Energy Dominance Financing Program, closed Sept 2024")
    press = Source.create!(url: "https://newswire.example/full-reactors-release", source_kind: "web_page", crawl_status: "ok")
    Evidence.where(subject: full).update_all(source_id: press.id)
    item = SocialAgent::Picker.new(platform: "linkedin", now: MONDAY).candidates.first
    assert_match "Loan of $1.52 billion under the Energy Dominance Financing Program, closed Sept 2024", item.facts["records of its links"]
    assert_no_match(/\bfunds\b/, item.facts["records of its links"], "no 'funds' present-tense verb")
    assert_equal "a page on newswire.example", item.facts["description comes from"]
    assert_equal "a page on newswire.example", item.facts["headquarters comes from"]
    assert_no_match(/own website/, item.facts.values_at("description comes from", "headquarters comes from").join(" "), "a press-release fact is never 'its website'")
  end

  test "a spotlight puts the company only where the directory's headquarters is (Helion: Redmond was an award's location, the headquarters is Everett)" do
    item = SocialAgent::Item.new(subject: @company, kind: "spotlight", facts: { "name" => "Helion Energy", "headquarters" => "Everett, WA" }, source_url: "https://helionenergy.com", source_quote: "x", path: "/companies/helion", organization_ids: [])
    assert_equal [ "it puts the company in Redmond, but its headquarters in the directory is Everett, WA" ], SocialAgent::Rules.headquarters("Meet Helion Energy: it is based in Redmond, WA.", item)
    assert_empty SocialAgent::Rules.headquarters("Meet Helion Energy: it is headquartered in Everett, Washington.", item)
    assert_empty SocialAgent::Rules.headquarters("Meet Helion Energy: it builds a fusion plant.", item), "no place said"
    news = item.with(kind: "news")
    assert_empty SocialAgent::Rules.headquarters("It is based in Redmond, WA.", news), "only spotlights"
  end

  test "a spotlight isn't stopped for a qualifier that appears only in another story on the company's site (GTM, Helion's letter of intent)" do
    item = SocialAgent::Item.new(subject: @company, kind: "spotlight", facts: { "name" => "Helion Energy", "headquarters" => "Everett, WA" }, source_url: "https://helionenergy.com",
      source_quote: "Fusion company.", path: "/companies/helion", organization_ids: [], page_text: "News: Helion signed a non-binding letter of intent with the Department of Commerce.")
    assert_empty SocialAgent::Rules.qualifiers("Meet Helion Energy: it is a fusion company based in Everett, WA.", item)
    news = item.with(kind: "news", facts: { "headline" => "Helion signs a letter of intent" })
    assert_not_empty SocialAgent::Rules.qualifiers("Helion said it signed a deal.", news), "a news item still keeps its source's qualifiers"
    planned = item.with(facts: { "name" => "NuScale", "records of its links" => "Announced plan (Oct 2023) for planned SMR plants" })
    assert_empty SocialAgent::Rules.qualifiers("Meet NuScale: the directory lists two DOE awards.", planned), "a link the post doesn't mention keeps its qualifier out of the way"
  end

  test "'first in 2015, latest in 2019' is an order, not a claim to be first" do
    assert_empty SocialAgent::Rules.unattributed_superlatives("DOE made two awards, first in 2015 and latest in 2019.")
  end

  test "a link with no date anywhere isn't told in a spotlight (DQ: undated ARPA-E funding)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    deal = Relationship.where(from_organization: full).first
    deal.update!(relationship_type: "funds", description: "Research funding", started_on: nil)
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates, "its only link has no date"
    deal.update!(description: "Research funding awarded in 2019")
    assert_equal 1, SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.size, "a year in its own words is a date"
  end

  test "the picker skips a news item whose words are only radiation or isotopes (NASA bone-marrow chip, 21 Nov)" do
    # News item 55 exactly as stored (DQ): its only nuclear-ish word is "ionizing radiation".
    @news.update_columns(title: "BPS Digital AVATAR Challenge", headline: "NASA features BPS Digital AVATAR Challenge", publisher: "NASA",
      summary: "NASA's Space Biology Program investigates how living systems respond to spaceflight stressors, including microgravity and ionizing radiation.")
    assert_nil SocialAgent::Picker.new(platform: "x", now: MONDAY).call
  end

  test "the send-time recheck finds a spotlight draft's own company (its draft doesn't exclude it) and every post kind (#880 with #884)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    draft = SocialPost.create!(platform: "x", status: "drafted", subject: full, text: "Meet Full Reactors: according to its website, it designs small modular reactors. Per the directory's records, in October 2023 it announced a plan to provide 24 modules to Full Reactors Partner.",
      link: "https://nuclear-directory.org/companies/full-reactors", source_url: "https://full-reactors.example/about", organization_ids: [ full.id ], created_at: MONDAY - 1.hour)
    assert_nil SocialAgent.recheck(draft, MONDAY, OK_FETCHER.new(200)), "the draft passes its own recheck"
  end

  test "spotlight picker (Copilot, #884): both ends of a told deal are reserved, an HQ field without a backing quote isn't trusted, a gov-page description isn't 'its website', a company this platform already sent is not picked, no founding year without a quote" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    deal = Relationship.where(from_organization: full).first
    item = SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.first
    assert_equal [ full.id, deal.to_organization_id ].sort, item.organization_ids.sort, "the counterparty is reserved for the day too"
    assert_nil item.facts["founded"], "no founding year without a quote that covers it"

    full.update_columns(founded_year: 1999)
    assert_nil SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.first.facts["founded"]

    # An HQ field with no quote that names that city and state is not a headquarters.
    full.update_columns(hq_city: "Reno", hq_state: "NV")
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates, "the quotes say Austin, Texas, not Reno"
    full.update_columns(hq_city: "Austin", hq_state: "Texas")

    # A description sourced from a regulator's page is not 'the company's own website' and doesn't become the source.
    nrc = Source.create!(url: "https://www.nrc.gov/reading-rm/doc.html", source_kind: "web_page", crawl_status: "ok")
    Evidence.where(subject: full, fields: [ "description" ]).update_all(source_id: nrc.id)
    gov = SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.first
    assert_equal "a page on nrc.gov", gov.facts["description comes from"]
    assert_equal "https://full-reactors.example", gov.source_url, "the company's website, not the NRC page"

    # A send already on this platform (any age): never picked, the one-send index would refuse it.
    SocialPost.create!(platform: "x", status: "posted", subject: full, text: "Old.", created_at: MONDAY - 20.weeks)
    assert_empty SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates
    assert_equal 1, SocialAgent::Picker.new(platform: "linkedin", now: MONDAY).candidates.size, "another platform is fine"
  end

  test "a link's source is the page whose quote states the link, not just the first evidence row (Founder: the loan is on energy.gov, not USAspending)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    deal = Relationship.where(from_organization: full).first
    deal.update!(relationship_type: "funds", description: "Loan of $1.52 billion under the Energy Dominance Financing Program, closed Sept 2024")
    deal.evidence.destroy_all
    award = Source.create!(url: "https://www.usaspending.gov/award/1", source_kind: "web_page", crawl_status: "ok")
    loan = Source.create!(url: "https://www.energy.gov/lpo/full-reactors", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: deal, source: award, quote: "Award of $2 million, 2023", found_by: "human")
    Evidence.create!(subject: deal, source: loan, quote: "closed a loan of $1.52 billion under the Energy Dominance Financing Program in September 2024", found_by: "human")
    facts = SocialAgent::Picker.new(platform: "linkedin", now: MONDAY).candidates.first.facts
    assert_match "[source: a page on energy.gov]", facts["records of its links"]
    assert_no_match(/usaspending/, facts["records of its links"])
  end

  test "a link whose supporting quote names the borrower carries that party (Holtec Palisades, LLC), and the judge is told a partial list fails (DQ, #884)" do
    ENV.delete("SOCIAL_POST_KINDS")
    full = spotlight_company("Full Reactors", "full-reactors")
    deal = Relationship.where(from_organization: full).first
    deal.update!(relationship_type: "funds", description: "Loan of $1.52 billion under the Energy Dominance Financing Program, closed Sept 2024")
    deal.evidence.destroy_all
    loan = Source.create!(url: "https://www.energy.gov/edf/palisades", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: deal, source: loan, quote: "Owners: Full Reactors Palisades, LLC | Loan: $1.52 billion under the Energy Dominance Financing Program, closed September 2024", found_by: "human")
    facts = SocialAgent::Picker.new(platform: "linkedin", now: MONDAY).candidates.first.facts
    assert_match "[the source names the party as: Full Reactors Palisades, LLC]", facts["records of its links"]
    assert_match "keeps only some items of a list", SocialAgent::Writer::NITS
    assert_equal "Full Reactors Palisades, LLC", SocialAgent::Picker.new(platform: "x", now: MONDAY).send(:named_party, "Recipient: Full Reactors Palisades, LLC; amount 2 million")
  end

  test "'its website describes it', 'the directory lists' and a month written out for the source's abbreviation are fine (rehearsal 11)" do
    assert SocialAgent::Rules.attributed?("Its website describes it as a reactor developer.")
    assert_empty SocialAgent::Rules.unattributed_superlatives("The directory lists that Helion would supply electricity from its first fusion plant.")
    assert_not_empty SocialAgent::Rules.unattributed_superlatives("It is the first fusion company.")
    item = SocialAgent::Item.new(subject: @company, kind: "spotlight", facts: { "name" => "X-energy" }, source_url: "https://x-energy.com", source_quote: "ARDP award: Oct 2020, $80M initial funding",
      path: "/companies/x", organization_ids: [])
    assert_empty SocialAgent::Check.problems("Meet X-energy. The directory lists an October 2020 award of $80M initial funding.", item, platform: "linkedin").grep(/October/)
    assert_not_empty SocialAgent::Check.problems("Meet X-energy. The directory lists a March 2020 award.", item, platform: "linkedin").grep(/March/)
  end

  test "HQ fact Everett, WA with page text that says Redmond: a post placing Helion in Redmond is stopped by the full problems, Everett passes the place gate (DQ)" do
    item = SocialAgent::Item.new(subject: @company, kind: "spotlight", facts: { "name" => "Helion Energy", "headquarters" => "Everett, WA", "description" => "Fusion company building a fusion power plant." },
      source_url: "https://helionenergy.com", source_quote: "Fusion company building a fusion power plant.\nEverett, WA", path: "/companies/helion-energy", organization_ids: [],
      page_text: "Helion's 2014 ARPA-E project, Compression of FRC Targets for Fusion, was run from Redmond, WA. Headquartered in Everett, WA.")
    assert_includes SocialAgent::Rules.headquarters("Meet Helion Energy: it is a fusion company based in Redmond, WA.", item).join, "its headquarters in the directory is Everett, WA"
    assert_empty SocialAgent::Rules.headquarters("Meet Helion Energy: it is a fusion company based in Everett, WA.", item)
    # The page text mentions Redmond and Everett; only the directory's HQ field decides where the post may place the company.
    assert_match(/Redmond/, item.page_text)
  end

  test "spotlight openers rotate: each post gets a pattern not used in the last five posts on its platform, and an opener repeating one of them is blocked (Tosin: not always 'Meet X')" do
    ENV.delete("SOCIAL_POST_KINDS")
    patterns = SocialAgent::Openers.patterns
    assert patterns.size >= 6
    full = spotlight_company("Full Reactors", "full-reactors")
    assert_equal 0, SocialAgent::Openers.next_for("x")

    # Five earlier posts on X, one per opener 0..4, so the next free pattern is 5.
    5.times do |index|
      other = Organization.create!(name: "Co #{index}", slug: "co-#{index}", verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.year)
      SocialPost.create!(platform: "x", status: "posted", subject: other, text: "#{SocialAgent::Openers.fill(patterns[index], other.name)} It does things.", created_at: MONDAY - (10 - index).days)
    end
    assert_equal [ 4, 3, 2, 1, 0 ], SocialAgent::Openers.recent("x")
    assert_equal 5, SocialAgent::Openers.next_for("x")
    assert_equal 0, SocialAgent::Openers.next_for("linkedin"), "another platform has its own history"
    item = SocialAgent::Picker.new(platform: "x", now: MONDAY).candidates.find { |candidate| candidate.subject == full }
    assert_equal SocialAgent::Openers.fill(patterns[5], "Full Reactors"), item.facts["required opener"]

    ok = "#{SocialAgent::Openers.fill(patterns[5], 'Full Reactors')} According to its website, it designs small modular reactors."
    assert_empty SocialAgent::Rules.opener(ok, item, platform: "x")
    repeated = "#{SocialAgent::Openers.fill(patterns[0], 'Full Reactors')} According to its website, it designs small modular reactors."
    problems = SocialAgent::Rules.opener(repeated, item, platform: "x")
    assert_match(/doesn't open with the required opener/, problems.join)
    assert_match(/opens like one of the last 5 posts on x/, problems.join)
    assert_empty SocialAgent::Rules.opener(repeated, item, platform: "linkedin").grep(/last 5 posts/), "not repeated on LinkedIn"
  end
end
