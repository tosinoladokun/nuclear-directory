require "test_helper"

class DataQuality::Plugins::LeadForwardsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::LeadForwards
  API = DataQuality::Plugins::Newsletters::API
  FakeLLM = Struct.new(:data) do
    def structured(**) = DataQuality::OpenRouter::Client::Response.new(data:, model: "fake", usage: {})
  end
  TEXT = "Worth a look: Fresh Fission is building a microreactor. Acme Fission too. https://www.linkedin.com/company/fresh-fission\nhttps://example.com/x?token=secret"

  setup do
    Organization.create!(name: "Acme Fission", verification_status: "verified", verified_by: "human:tosin").aliases.find_or_create_by!(alias: "Acme Fission")
    mail = { "id" => "f1", "to" => [ Plugin::INBOX ], "from" => "Owner <owner@example.com>", "subject" => "Fwd: ideas" }
    @answers = {
      "#{API}?limit=100" => { "has_more" => false, "data" => [ mail, mail.merge("id" => "f2", "from" => "Stranger <someone@example.net>"),
        mail.merge("id" => "f3", "from" => "\"owner@example.com\" <attacker@example.net>") ] },
      "#{API}/f1" => mail.merge("html" => nil, "text" => TEXT, "authentication" => { "dmarc" => "pass" })
    }
    @asked, @replies = [], []
  end

  def http = ->(url, _headers) { @asked << url; (body = @answers[url]&.to_json) ? [ 200, body, nil ] : [ 404, nil, nil ] }
  def plugin(found = {}) = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new(found), sleeper: ->(_) { }, forwarders: "owner@example.com",
    sender: ->(**reply) { @replies << reply; true })

  test "reads only the allow-listed sender's mail to leads@, and nothing without the list" do
    assert_equal 1, plugin.crawl(nil)["emails"]
    refute(@asked.any? { |url| url.end_with?("/f2", "/f3") }, "another sender or a spoofed display name is never opened")
    assert_equal({ "skipped" => "no LEADS_ALLOWED_SENDERS" }, Plugin.new(http:, api_key: "re_test", forwarders: "").crawl(nil))
  end

  test "each company becomes a lead, listed ones are skipped, and one short reply goes back, once" do
    plugin.crawl(nil)
    source = Source.find_by!(source_kind: "lead_forwards")
    found = { "companies" => [ { "name" => "Fresh Fission", "quote" => "Fresh Fission is building a microreactor.", "website" => nil },
      { "name" => "Acme Fission", "quote" => "Acme Fission too.", "website" => nil } ] }
    plugin(found).extract(source, nil)
    plugin(found).extract(source.reload, nil)

    assert_equal [ "Fresh Fission" ], Lead.pluck(:name)
    assert_equal 1, @replies.size
    assert_equal({ to: "owner@example.com", subject: "Re: Fwd: ideas", text: "Added 1 lead: Fresh Fission.\nAlready listed: Acme Fission.",
      key: "lead-forwards-#{source.id}" }, @replies.sole)
    assert_not_requested :get, /linkedin/
  end

  test "a text-only email's URLs are cleaned like links (Copilot)" do
    plugin.crawl(nil)
    kept = Source.find_by!(source_kind: "lead_forwards").content_text
    refute_includes kept, "token=secret"
    assert_includes kept, "https://example.com/x"
  end

  test "a failed reply raises, so the next run tries again with the same key (Copilot)" do
    plugin.crawl(nil)
    source = Source.find_by!(source_kind: "lead_forwards")
    failing = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new({ "companies" => [] }), sleeper: ->(_) { }, forwarders: "owner@example.com",
      sender: ->(**) { false })
    assert_raises(Plugin::ReplyFailed) { failing.extract(source, nil) }
    assert_nil source.reload.etag
  end

  test "the reply goes to the allow-listed address that sent it (Infra)" do
    @answers["#{API}?limit=100"]["data"].first["from"] = "Owner <second@example.com>"
    @answers["#{API}/f1"]["from"] = "Owner <second@example.com>"
    two = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new({ "companies" => [] }), sleeper: ->(_) { }, forwarders: "owner@example.com, second@example.com",
      sender: ->(**reply) { @replies << reply; true })
    two.crawl(nil)
    two.extract(Source.find_by!(source_kind: "lead_forwards"), nil)
    assert_equal "second@example.com", @replies.sole[:to]
    refute_includes Source.find_by!(source_kind: "lead_forwards").attributes.values.join(" "), "second@example.com", "no address stored"
  end

  test "a whole-domain entry lets in that exact domain only, replies to the sender, and our own domain never (PM, 11 Nov)" do
    domain = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new({ "companies" => [] }), sleeper: ->(_) { }, forwarders: "@example.org, @mail.nuclear-directory.org",
      sender: ->(**reply) { @replies << reply; true })
    assert domain.send(:sender?, "Someone <someone@example.org>")
    refute domain.send(:sender?, "x@sub.example.org"), "no subdomains"
    refute domain.send(:sender?, "x@example.org.evil.net")
    refute domain.send(:sender?, "bot@mail.nuclear-directory.org"), "our own sender, even if listed"
    refute domain.send(:sender?, "\"someone@example.org\" <attacker@example.net>"), "a display name never counts"
    assert domain.send(:sender?, "Someone <SOMEONE@Example.ORG>"), "case-insensitive"

    @answers["#{API}?limit=100"]["data"].first["from"] = "Someone <someone@example.org>"
    @answers["#{API}/f1"]["from"] = "Someone <someone@example.org>"
    domain.crawl(nil)
    domain.extract(Source.find_by!(source_kind: "lead_forwards"), nil)
    assert_equal "someone@example.org", @replies.sole[:to]
  end

  test "a whole-domain sender whose DMARC failed is recorded, never read (PM)" do
    @answers["#{API}?limit=100"]["data"].first["from"] = "Someone <someone@example.org>"
    @answers["#{API}/f1"] = @answers["#{API}/f1"].merge("from" => "Someone <someone@example.org>", "authentication" => { "dmarc" => "fail" })
    domain = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new({}), sleeper: ->(_) { }, forwarders: "@example.org", sender: ->(**) { true })
    assert_equal 0, domain.crawl(nil)["emails"]
    assert Source.find_by!(source_kind: "lead_forwards").crawl_needs_human?
  end

  test "a whole public mail domain is never an entry (Infra)" do
    listed = Plugin.new(http:, api_key: "re_test", forwarders: "@gmail.com, owner@gmail.com")
    refute listed.send(:sender?, "someone@gmail.com"), "@gmail.com is ignored"
    assert listed.send(:sender?, "owner@gmail.com"), "an exact address there still counts"
  end
end
