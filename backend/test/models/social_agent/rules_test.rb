require "test_helper"

# The fixed rules before a post goes out (#769, PM 18 Nov): primary source that answers now, status words the source
# uses, no person, no unquoted superlative, no sensitive topic, no near-repeat, no federal holiday, Buffer's allowance.
class SocialAgent::RulesTest < ActiveSupport::TestCase
  Rules = SocialAgent::Rules
  OK = Struct.new(:status, :body) { def get(_url) = DataQuality::Fetcher::Response.new(url: "", kind: status == 200 ? :ok : :blocked, status:, body: body.to_s,
    etag: nil, last_modified: nil, reason: "blocked", block_reference: nil, content_type: nil, truncated: false) }

  setup do
    @company = Organization.create!(name: "Acme Fission", domain: "acmefission.com", verification_status: "verified", verified_by: "human:tosin")
  end

  def item(url: "https://www.nrc.gov/notice", quote: "The NRC received Acme Fission's construction permit application.")
    SocialAgent::Item.new(subject: @company, kind: "news", facts: { "companies" => "Acme Fission", "publisher" => "NRC" },
      source_url: url, source_quote: quote, path: "/", organization_ids: [ @company.id ])
  end

  test "a clean post from a primary source passes" do
    assert_empty Rules.problems("The NRC said it received Acme Fission's construction permit application.", item, platform: "x", fetcher: OK.new(200))
    assert_equal [ "it doesn't say where the item comes from in words (\"the company said\", \"DOE said\", \"in a Federal Register notice\")" ],
      Rules.problems("Acme Fission's construction permit application was received.", item, platform: "x", fetcher: OK.new(200)), "the source is named in words (Tosin, 20 Nov)"
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
    SocialChannel.for("x").update!(mode: "drafts")
    (SocialAgent::Buffer::MONTHLY_REQUESTS * SocialAgent::Buffer::ALERT_AT / SocialAgent::Buffer::PER_POST).ceil.times do |n|
      SocialPost.create!(platform: "linkedin", status: "failed", subject: @company, external_id: "b#{n}", created_at: 2.days.ago)
    end
    assert_nil SocialAgent.run("x", writer: Object.new)
    channel = SocialChannel.for("x")
    assert_equal [ "off", "Buffer's 30-day request allowance is 80% used" ], [ channel.mode, channel.paused_reason ]
  end

  test "every superlative, plural sensitive words, export controls, a leading article, plant aliases, and the page itself" do
    src = item(quote: "The NRC received Acme Fission's first application.")
    assert_includes Rules.problems("Acme Fission filed its first and largest application.", src, platform: "x", fetcher: OK.new(200)),
      "it says \"largest\", which its source doesn't"
    assert_match "lawsuits", Rules.problems("The NRC received two lawsuits about Acme Fission.", item, platform: "x", fetcher: OK.new(200)).join
    assert_match "export controls", Rules.problems("Export controls apply to the NRC application.", item, platform: "x", fetcher: OK.new(200)).join
    assert_includes Rules.problems("The Jane Doe statement covered the NRC application.", item, platform: "x", fetcher: OK.new(200)), "it may name a person (Jane Doe)"
    plant = Facility.create!(name: "Crane Clean Energy Center", facility_type: "power_reactor")
    plant.aliases.create!(alias: "Three Mile Island")
    assert_empty Rules.people("Three Mile Island is near the NRC office.", item)
    assert_match "source page touches a sensitive topic (contamination)",
      Rules.problems("The NRC received Acme Fission's construction permit application.", item, platform: "x", fetcher: OK.new(200, "after contamination was found")).join
  end

  test "engineering terms aren't sensitive; real accident, injury and death wording still is (#1017)" do
    fine = [ "Acme Fission finished a fatal flaws evaluation for the NRC application site.",
      "Acme Fission filed a fatal-flaw study with its NRC application.",
      "The NRC application includes severe accident mitigation analyses.",
      "Acme Fission's NRC application covers accident tolerant fuel." ]
    fine.each { |text| assert_nil Rules.sensitive(text), text }
    assert_no_match "sensitive", Rules.problems(fine.first, item, platform: "x", fetcher: OK.new(200)).join
    assert_empty Rules.source_problems("https://www.nrc.gov/notice",
      OK.new(200, "<article><p>A fatal flaws evaluation found the site suitable. Severe accident mitigation analyses followed.</p></article>"))

    { "A fatal accident closed the NRC site." => "fatal", "Two workers were injured at the NRC site." => "injured",
      "One worker died after a fatal flaws evaluation." => "died", "A severe accident at the plant." => "accident",
      "The fuel was accident tolerant until the accident." => "accident" }.each do |text, word|
      assert_equal word, Rules.sensitive(text), text
    end
    assert_equal [ "its source page touches a sensitive topic (killed)" ], Rules.source_problems("https://www.nrc.gov/notice",
      OK.new(200, "<article><p>A fatal flaws evaluation was done. A falling crane killed a worker.</p></article>"))
  end
end
