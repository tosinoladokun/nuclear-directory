require "test_helper"

# The fixed rules before a post goes out (#769, PM 18 Nov): primary source that answers now, status words the source
# uses, no person, no unquoted superlative, no sensitive topic, no near-repeat, no federal holiday, Buffer's allowance.
class SocialAgent::RulesTest < ActiveSupport::TestCase
  Rules = SocialAgent::Rules
  OK = Struct.new(:status) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: status == 200 ? :ok : :blocked, status:, body: "",
    etag: nil, last_modified: nil, reason: "blocked", block_reference: nil, content_type: nil, truncated: false) }

  setup do
    @company = Organization.create!(name: "Acme Fission", domain: "acmefission.com", verification_status: "verified", verified_by: "human:tosin")
  end

  def item(url: "https://www.nrc.gov/notice", quote: "The NRC received Acme Fission's construction permit application.")
    SocialAgent::Item.new(subject: @company, kind: "news", facts: { "companies" => "Acme Fission", "publisher" => "NRC" },
      source_url: url, source_quote: quote, path: "/", organization_ids: [ @company.id ])
  end

  test "a clean post from a primary source passes" do
    assert_empty Rules.problems("The NRC received Acme Fission's construction permit application.", item, platform: "x", fetcher: OK.new(200))
  end

  test "primary sources: government, or the company's own site; a news outlet isn't" do
    assert Rules.primary?(item(url: "https://www.federalregister.gov/d/1"))
    assert Rules.primary?(item(url: "https://news.acmefission.com/release"))
    assert_not Rules.primary?(item(url: "https://www.reuters.com/story"))
  end

  test "a status word the source doesn't use, a person, a superlative, a sensitive topic each stop it" do
    text = "The NRC approved Acme Fission's construction permit application."
    assert_includes Rules.problems(text, item, platform: "x", fetcher: OK.new(200)), "it says \"approved\", which its source doesn't"
    assert_includes Rules.problems("Jane Doe said the NRC received Acme Fission's application.", item, platform: "x", fetcher: OK.new(200)),
      "it may name a person (Jane Doe)"
    assert_includes Rules.problems("The NRC received Acme Fission's loan application.", item, platform: "x", fetcher: OK.new(200)),
      "it says \"loan\", which its source doesn't"
    assert_match "framework", Rules.problems("Acme Fission and the NRC signed a framework.", item, platform: "x", fetcher: OK.new(200)).join
    assert_match "largest", Rules.problems("Acme Fission filed the largest application.", item, platform: "x", fetcher: OK.new(200)).join
    assert_match "sensitive", Rules.problems("The NRC received Acme Fission's application after an incident.", item, platform: "x", fetcher: OK.new(200)).join
  end

  test "the source must answer 200 now; a block isn't retried" do
    assert_equal [ "its source didn't answer (403)" ], Rules.problems("The NRC received Acme Fission's construction permit application.", item, platform: "x", fetcher: OK.new(403))
  end

  test "a near-repeat of a recent post on the platform stops it" do
    SocialPost.create!(platform: "x", status: "posted", subject: @company, text: "The NRC received Acme Fission's construction permit application.")
    assert_includes Rules.problems("The NRC received Acme Fission's construction permit application.", item, platform: "x", fetcher: OK.new(200)),
      "it's too like a post from the last 60 days"
  end

  test "US federal holidays, with weekend ones observed" do
    assert Rules.holiday?(Date.new(2026, 11, 26)), "Thanksgiving"
    assert Rules.holiday?(Date.new(2026, 7, 3)), "Independence Day on a Saturday is observed Friday"
    assert Rules.holiday?(Date.new(2026, 1, 19)), "Martin Luther King Jr. Day"
    assert_not Rules.holiday?(Date.new(2026, 11, 16))
  end

  test "Buffer's allowance at 80% switches posting off and says so" do
    travel_to Time.find_zone(SocialAgent::ZONE).local(2026, 11, 16, 8, 30)
    SocialAgent::Buffer::COUNTS.clear
    SocialChannel.for("x").update!(mode: "drafts")
    SocialAgent::Buffer::COUNTS.write("buffer_requests:#{Date.current.iso8601}", SocialAgent::Buffer::MONTHLY_REQUESTS, raw: true)
    assert_nil SocialAgent.run("x", writer: Object.new)
    channel = SocialChannel.for("x")
    assert_equal [ "off", "Buffer's 30-day request allowance is 80% used" ], [ channel.mode, channel.paused_reason ]
  ensure
    SocialAgent::Buffer::COUNTS.clear
  end
end
