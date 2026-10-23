require "test_helper"

# The fixture is the Federal Register API's real answer for the NRC's
# notices of the 60 days to 2026-10-22, fetched with the Fetcher's user agent.
class DataQuality::Plugins::FederalRegisterNrcTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::FederalRegisterNrc
  TODAY = Date.new(2026, 10, 22)
  PIONEER = "SMR, LLC; Palisades SMR, LLC; Pioneer Units 1 and 2; Phased Construction Permit Application-Limited Work Authorization".freeze

  setup do
    stub_request(:get, "https://www.federalregister.gov/robots.txt").to_return(body: "User-Agent: *\nDisallow: /documents/search\n")
    @api = stub_request(:get, /\Ahttps:\/\/www\.federalregister\.gov\/api\/v1\/documents\.json\?/).to_return(body: json, headers: { "Content-Type" => "application/json" })
  end

  def json = file_fixture("federal_register/nrc_notices.json").read
  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY })
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def source = Source.find_by!(url: Plugin::API_URL)

  test "is the plug-in for federal_register_nrc" do
    assert_instance_of Plugin, DataQuality::Plugin.for("federal_register_nrc")
  end

  test "asks for the NRC's notices of the window once a day, keeping the plain address" do
    run = crawl
    second = crawl

    assert_equal "changed", run.stats["notices"]
    assert_equal "skipped_recent", second.stats["notices"]
    assert_requested :get, /nuclear-regulatory-commission.*gte%5D=2026-08-23/, times: 1
    assert_equal Plugin::API_URL, source.url
  end

  test "a block stops the crawl" do
    stub_request(:get, /federalregister\.gov\/api/).to_return(status: 403, body: "Forbidden")

    assert_equal "notices blocked", crawl.stats["stopped"]
    assert source.crawl_blocked?
  end

  test "each notice about a named licensee is a news item about what its title names; repeats once; no forms or Commissioners" do
    crawl
    candidates = plugin.extract(source, nil)
    titles = candidates.map { |c| c[:quote] }

    assert_equal titles.uniq, titles, "a weekly repeat is proposed once"
    assert_equal 1, titles.count(PIONEER)
    refute titles.any? { |t| t.match?(/Information Collection|Biweekly|Commissioner/) }
    assert candidates.all? { |c| plugin.quote_in_source?(source, c[:quote]) }

    pioneer = candidates.find { |c| c[:quote] == PIONEER }
    assert_equal "2026-10-01", pioneer[:payload]["published_on"], "from its first date"
    assert_equal "Federal Register (NRC)", pioneer[:payload]["publisher"]
    assert_match %r{\Ahttps://www\.federalregister\.gov/documents/2026/10/01/}, pioneer[:payload]["url"]
    assert_equal [ "SMR, LLC", "Palisades SMR, LLC", "Pioneer Units 1 and 2" ], pioneer[:payload]["about"].map { |a| a["name"] }.uniq
    assert pioneer[:payload]["summary"].length <= Plugin::SUMMARY_LENGTH
  end

  test "a notice a person already decided isn't proposed again, nor its weekly repeat" do
    crawl
    first = plugin.extract(source, nil).find { |c| c[:quote] == PIONEER }
    source.candidates.create!(kind: "news_item", status: "rejected", quote: PIONEER, payload: first[:payload])

    refute_includes plugin.extract(source, nil).map { |c| c[:quote] }, PIONEER
  end

  test "match: a notice about a company in the directory attaches to it" do
    company = Organization.create!(name: "Tennessee Valley Authority").tap { |c| c.verify!(by: "human:tosin"); c.aliases.create!(alias: c.name) }

    DataQuality::Pipeline.run("federal_register_nrc", plugin:, only: %w[crawl extract match])

    claim = Candidate.where(kind: "news_item").find { |c| c.quote.start_with?("Tennessee Valley Authority;") }
    assert_equal [ "matched", company.id ], [ claim.status, claim.subject_id ]
  end
end
