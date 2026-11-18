require "test_helper"

# The social agent (#769): one checked post per platform each weekday about fresh, published directory data.
class SocialAgentTest < ActiveSupport::TestCase
  BY = "human:tosin"
  MONDAY = Time.find_zone(SocialAgent::ZONE).local(2026, 11, 16, 8, 30)

  # Writes what it's told and judges with the answer it's given; no model call.
  class FakeWriter
    attr_accessor :text, :voice
    def initialize(text, voice: [ true, nil ]) = (@text, @voice = text, voice)
    def draft(_item, platform:) = text
    def voice_ok?(_text, _item) = voice
  end

  setup do
    @company = Organization.create!(name: "Acme Fission", slug: "acme-fission", verification_status: "verified", verified_by: BY, verified_at: 1.year.ago)
    @news = NewsItem.create!(url: "https://example.com/acme-award", title: "Acme Fission wins $1,404,253 DOE award for fuel cladding",
      summary: "The Department of Energy awarded Acme Fission $1,404,253 to test fuel cladding.", publisher: "DOE",
      published_on: Date.new(2026, 11, 12), verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.day)
    @news.news_mentions.create!(subject: @company)
    SocialChannel.for("x").update!(mode: "drafts")
  end

  def run_x(text, **options) = SocialAgent.run("x", now: MONDAY, writer: FakeWriter.new(text, **options))

  test "drafts one checked post on the freshest published news, linked to its company with tracking" do
    post = run_x("The Department of Energy awarded Acme Fission $1,404,253 to test fuel cladding.")
    assert_equal [ "drafted", @news ], [ post.status, post.subject ]
    assert_equal "https://nuclear-directory.org/companies/acme-fission?utm_source=x&utm_medium=social&utm_campaign=news", post.link
    assert_equal "https://example.com/acme-award", post.source_url
    assert_nil run_x("Again."), "one a day per platform"
  end

  test "a number or name the source doesn't have stops the post, as does the voice check" do
    assert_match "the number 2 isn't in the source", run_x("Acme Fission won 2 DOE awards.").reason
    SocialPost.delete_all
    assert_match "the name \"Westinghouse\" isn't in the source", run_x("Acme Fission and Westinghouse won a DOE award.").reason
    SocialPost.delete_all
    assert_match "voice check: reads like an ad", run_x("Acme Fission won a DOE award.", voice: [ false, "reads like an ad" ]).reason
    SocialPost.delete_all
    assert_match "hashtag", run_x("Acme Fission won a DOE award. #nuclear").reason
  end

  test "people and event items aren't news; relative time is stopped" do
    @news.update_columns(title: "Acme Fission engineer named to 40 Under 40")
    assert_nil run_x("Acme Fission won a DOE award.")
    @news.update_columns(title: "Acme Fission wins $1,404,253 DOE award for fuel cladding")
    assert_match "\"today\" instead of a date", run_x("Today Acme Fission won a DOE award.").reason
  end

  test "off, weekends and nothing fresh post nothing; a fact used in the last two weeks isn't used again" do
    SocialChannel.for("x").update!(mode: "off")
    assert_nil run_x("Acme Fission won a DOE award.")
    SocialChannel.for("x").update!(mode: "drafts")
    assert_nil SocialAgent.run("x", now: MONDAY - 2.days, writer: FakeWriter.new("Acme Fission won a DOE award.")), "Saturday"
    SocialPost.create!(platform: "linkedin", status: "posted", subject: @news, created_at: MONDAY - 10.days)
    assert_nil run_x("Acme Fission won a DOE award."), "used on LinkedIn 10 days ago"
  end

  test "a newly added company is used when there's no fresh news" do
    @news.update_columns(verified_at: MONDAY - 20.days)
    company = Organization.create!(name: "Beta Reactors", slug: "beta-reactors", description: "Beta Reactors designs small reactors.",
      verification_status: "verified", verified_by: BY, verified_at: MONDAY - 1.day)
    VerificationEvent.where(subject: company).update_all(created_at: MONDAY - 1.day)
    VerificationEvent.where(subject: @company).update_all(created_at: MONDAY - 1.day)
    VerificationEvent.create!(subject: @company, to_status: "verified", by: BY, created_at: MONDAY - 1.year)
    post = run_x("Beta Reactors designs small reactors.")
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

  DRAFT = "The Department of Energy awarded Acme Fission $1,404,253 to test fuel cladding.".freeze

  test "live sends once through the platform's sender, costed, and logs the permalink" do
    live!
    sent = nil
    SocialAgent.senders["x"] = ->(text, link) { sent = [ text, link ]; { id: "1", permalink: "https://x.com/i/web/status/1" } }
    post = run_x(DRAFT)
    assert_equal [ "posted", "https://x.com/i/web/status/1", SocialAgent.post_cost ], [ post.status, post.permalink, post.cost_usd ]
    assert_equal post.link, sent.last
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
    assert_nil SocialAgent.run("x", now: MONDAY + 1.day, writer: FakeWriter.new(DRAFT)), "the same item is never picked again"
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
    assert_nil SocialAgent.run("x", now: MONDAY + 1.day, writer: FakeWriter.new(DRAFT)), "nor its item tomorrow"

    calls = []
    original = SocialAgent.method(:run)
    SocialAgent.define_singleton_method(:run) { |platform, **| calls << platform; raise "model down" if platform == "x" }
    SocialPostJob.perform_now
    assert_equal %w[x linkedin], calls
  ensure
    SocialAgent.define_singleton_method(:run, original) if original
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
end
