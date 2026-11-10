require "test_helper"

class DataQuality::Plugins::NewslettersTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::Newsletters
  FakeLLM = Struct.new(:data) do
    def structured(**) = DataQuality::OpenRouter::Client::Response.new(data:, model: "fake", usage: {})
  end
  HTML = <<~HTML.freeze
    <html><body><h2>Today in nuclear</h2>
    <p>Fresh Fission picked a site in Idaho for its first microreactor. <a href="https://www.freshfission.com/">Fresh Fission</a></p>
    <p>Tracked Atom signed a fuel deal. <a href="https://links.smartbrief.com/click?u=tracked">Read more</a></p>
    <p>Acme Fission raised money. <a href="https://www.acmefission.com">Acme</a></p>
    </body></html>
  HTML

  setup do
    Organization.create!(name: "Acme Fission", verification_status: "verified", verified_by: "human:tosin").aliases.find_or_create_by!(alias: "Acme Fission")
    @mail = { "id" => "m1", "to" => [ Plugin::INBOX ], "from" => "NEI SmartBrief <nei@smartbrief.com>", "subject" => "Today in nuclear" }
    @answers = {
      "#{Plugin::API}?limit=100" => { "has_more" => true, "data" => [ @mail, @mail.merge("id" => "m2", "from" => "spam@example.com"),
        @mail.merge("id" => "m3", "to" => [ "tosin@mail.nuclear-directory.org" ]),
        @mail.merge("id" => "m4", "from" => "\"News@smartbrief.com alert\" <attacker@example.net>") ] },
      "#{Plugin::API}?limit=100&after=m4" => { "has_more" => false, "data" => [ @mail.merge("id" => "m5") ] },
      "#{Plugin::API}/m5" => @mail.merge("id" => "m5", "html" => "<p>x</p>", "authentication" => { "dkim" => "fail" }),
      "#{Plugin::API}/m1" => @mail.merge("html" => HTML, "authentication" => { "dkim" => "pass" })
    }
    @asked = []
  end

  def http = ->(url, headers) { @asked << [ url, headers["Authorization"] ]; @answers[url]&.to_json }
  def plugin(found = {}) = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new(found))

  test "reads only bot@'s mail from newsletter senders, across pages, each email once (a rejected one too)" do
    assert_equal({ "emails" => 1, "opened" => 2 }, plugin.crawl(nil))
    assert_equal [ "Bearer re_test" ], @asked.map(&:last).uniq
    refute(@asked.any? { |url, _| url.end_with?("/m2", "/m3", "/m4") }, "another sender, another inbox or a spoofed display name is never opened")
    assert_includes Source.find_by!(url: "https://resend.com/emails/receiving/m1").title, "Today in nuclear"
    assert Source.find_by!(url: "https://resend.com/emails/receiving/m5").crawl_needs_human?, "DKIM failed: recorded, not stored"
    assert_equal({ "emails" => 0, "opened" => 0 }, plugin.crawl(nil))
  end

  test "without a key nothing is read; a failed listing with a key fails the crawl" do
    assert_equal({ "skipped" => "no RESEND_API_KEY" }, Plugin.new(http:, api_key: nil).crawl(nil))
    @answers.delete("#{Plugin::API}?limit=100")
    assert_raises(Plugin::InboxError) { plugin.crawl(nil) }
  end

  test "each new company becomes a lead (never a claim), with its own site only when the email links it" do
    plugin.crawl(nil)
    found = { "companies" => [
      { "name" => "Fresh Fission", "quote" => "Fresh Fission picked a site in Idaho for its first microreactor.", "website" => "https://www.freshfission.com/" },
      { "name" => "Tracked Atom", "quote" => "Tracked Atom signed a fuel deal.", "website" => "https://links.smartbrief.com/click?u=tracked" },
      { "name" => "Acme Fission", "quote" => "Acme Fission raised money.", "website" => "https://www.acmefission.com" },
      { "name" => "Ghost Nuclear", "quote" => "Ghost Nuclear is new.", "website" => "https://ghostnuclear.com" } ] }
    assert_empty plugin(found).extract(Source.find_by!(url: "https://resend.com/emails/receiving/m1"), nil)
    assert_equal({ "Fresh Fission" => "https://www.freshfission.com", "Tracked Atom" => nil },
      Lead.all.to_h { |lead| [ lead.name, lead.sources.sole["url"] ] }, "a tracker isn't a site; a company we have and a quote not in the email aren't leads")
  end

  test "is a daily source" do
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "newsletters"
    assert_instance_of Plugin, DataQuality::Plugin.for("newsletters")
  end
end
