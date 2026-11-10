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
      "#{Plugin::API}?limit=100" => { "data" => [ @mail, @mail.merge("id" => "m2", "from" => "spam@example.com"),
        @mail.merge("id" => "m3", "to" => [ "tosin@mail.nuclear-directory.org" ]) ] },
      "#{Plugin::API}/m1" => @mail.merge("html" => HTML, "authentication" => { "dkim" => "pass" })
    }
    @asked = []
  end

  def http = ->(url, headers) { @asked << [ url, headers["Authorization"] ]; @answers[url]&.to_json }
  def plugin(found = {}) = Plugin.new(http:, api_key: "re_test", llm: FakeLLM.new(found))

  test "reads only bot@'s mail from newsletter senders, each email once" do
    assert_equal({ "emails" => 1 }, plugin.crawl(nil))
    assert_equal [ "Bearer re_test" ], @asked.map(&:last).uniq
    refute(@asked.any? { |url, _| url.end_with?("/m2", "/m3") }, "another sender or another inbox is never opened")
    source = Source.find_by!(source_kind: "newsletters")
    assert_includes source.title, "Today in nuclear"
    assert_equal({ "emails" => 0 }, plugin.crawl(nil))
  end

  test "an email whose DKIM failed isn't stored; without a key nothing is read" do
    @answers["#{Plugin::API}/m1"]["authentication"] = { "dkim" => "fail" }
    assert_equal({ "emails" => 0 }, plugin.crawl(nil))
    assert_equal({ "skipped" => "no RESEND_API_KEY" }, Plugin.new(http:, api_key: nil).crawl(nil))
  end

  test "proposes a new company only with its own site linked in the email" do
    plugin.crawl(nil)
    found = { "companies" => [
      { "name" => "Fresh Fission", "quote" => "Fresh Fission picked a site in Idaho for its first microreactor.", "website" => "https://www.freshfission.com/" },
      { "name" => "Tracked Atom", "quote" => "Tracked Atom signed a fuel deal.", "website" => "https://links.smartbrief.com/click?u=tracked" },
      { "name" => "Acme Fission", "quote" => "Acme Fission raised money.", "website" => "https://www.acmefission.com" },
      { "name" => "Ghost Nuclear", "quote" => "Ghost Nuclear is new.", "website" => "https://ghostnuclear.com" } ] }
    claims = plugin(found).extract(Source.find_by!(source_kind: "newsletters"), nil)
    assert_equal [ { "name" => "Fresh Fission", "website" => "https://www.freshfission.com" } ], claims.map { |c| c[:payload] },
      "a tracker link, a company we have and a quote not in the email are never proposed"
  end

  test "is a daily source" do
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "newsletters"
    assert_instance_of Plugin, DataQuality::Plugin.for("newsletters")
  end
end
