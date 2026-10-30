require "test_helper"

# The fixture is the Federal Register API's real answer for the NRC's
# notices of the 60 days to 2026-10-22, fetched with the Fetcher's user agent.
class DataQuality::Plugins::FederalRegisterNrcTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::FederalRegisterNrc
  TODAY = Date.new(2026, 10, 22)
  PIONEER = "SMR, LLC; Palisades SMR, LLC; Pioneer Units 1 and 2; Phased Construction Permit Application-Limited Work Authorization".freeze
  NORTH_ANNA = /North Anna Site; Early Site Permit Renewal/

  setup do
    stub_request(:get, "https://www.federalregister.gov/robots.txt").to_return(body: "User-Agent: *\nDisallow: /documents/search\n")
    @api = stub_request(:get, %r{\Ahttps://www\.federalregister\.gov/api/v1/documents\.json\?}).to_return(body: json, headers: { "Content-Type" => "application/json" })
  end

  def json = file_fixture("federal_register/nrc_notices.json").read
  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY })
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def notices = Source.where(source_kind: "federal_register_nrc").order(:published_on, :id)

  test "is the plug-in for federal_register_nrc" do
    assert_instance_of Plugin, DataQuality::Plugin.for("federal_register_nrc")
  end

  test "asks for the NRC's notices once a day, and stores each one at its own Federal Register page" do
    run = crawl
    second = crawl

    assert_equal "changed", run.stats["notices"]
    assert_equal "skipped_recent", second.stats["notices"]
    assert_requested :get, /nuclear-regulatory-commission.*gte%5D=2026-08-23/, times: 1
    assert_equal "federal_register_index", Source.find_by!(url: Plugin::API_URL).source_kind
    assert notices.all? { |source| source.url.start_with?("https://www.federalregister.gov/documents/") }
    assert_equal run.stats["new"], notices.count
  end

  test "a block stops the crawl" do
    stub_request(:get, %r{federalregister\.gov/api}).to_return(status: 403, body: "Forbidden")

    assert_equal "notices blocked", crawl.stats["stopped"]
  end

  test "a weekly repeat is stored once; distinct notices with the same title are both kept; no forms or Commissioners" do
    crawl
    titles = notices.map(&:title)

    assert_equal 1, titles.count(PIONEER), "the 4 weekly notices are one"
    assert_equal "2026-10-01", notices.find { |s| s.title == PIONEER }.published_on.iso8601, "from its first date"
    assert_equal 2, titles.count { |t| t.match?(NORTH_ANNA) }, "receipt and the hearing opportunity are two notices"
    refute titles.any? { |t| t.match?(/Information Collection|Biweekly|Commissioner/) }
  end

  test "each notice is a news item citing its own page, about what its title names" do
    crawl
    source = notices.find { |s| s.title == PIONEER }
    claim = plugin.extract(source, nil).sole

    assert_equal source.url, claim[:payload]["url"]
    assert_equal "Federal Register (NRC)", claim[:payload]["publisher"]
    assert_equal [ { "name" => "SMR, LLC", "type" => "organization" }, { "name" => "Palisades SMR, LLC", "type" => "organization" },
      { "name" => "Pioneer Units 1 and 2", "type" => "facility" } ], claim[:payload]["about"]
    assert plugin.quote_in_source?(source, claim[:quote])
    assert claim[:payload]["summary"].length <= Plugin::SUMMARY_LENGTH
  end

  test "match: a notice about a company in the directory attaches to it, and its evidence is the notice's page" do
    company = Organization.create!(name: "Tennessee Valley Authority").tap { |c| c.verify!(by: "human:tosin"); c.aliases.create!(alias: c.name) }

    DataQuality::Pipeline.run("federal_register_nrc", plugin:, only: %w[crawl extract match])

    claim = Candidate.where(kind: "news_item").find { |c| c.quote.start_with?("Tennessee Valley Authority;") }
    assert_equal [ "matched", company.id ], [ claim.status, claim.subject_id ]
    assert_equal claim.payload["url"], claim.source.url
  end

  test "each notice gets a headline from its title's parts: what NRC did, then the site (DQ, 30 Oct)" do
    notice = ->(title) { Plugin::Notice.new(number: "1", published_on: "2026-10-28", title:, url: "https://www.federalregister.gov/d/1", abstract: nil) }
    p = Plugin.new
    assert_equal "Final environmental impact statement: Paducah Laser Enrichment Facility",
      p.headline(notice.("Global Laser Enrichment, LLC; Paducah Laser Enrichment Facility; Final Environmental Impact Statement"))
    assert_equal "License amendment application: Vistra Operations Company LLC",
      p.headline(notice.("Vistra Operations Company LLC; License Amendment Application"))
    assert_equal "Environmental assessment: Christopher M. Crane Clean Energy Center",
      p.headline(notice.("Constellation Energy Generation, LLC; Christopher M. Crane Clean Energy Center; Environmental Assessment and Finding of No Significant Impact"))
    assert_equal "Phased construction permit application: Pioneer Units 1 and 2",
      p.headline(notice.("Pioneer Energy, LLC; Pioneer Units 1 and 2; Phased Construction Permit Application-Limited Work Authorization"))
    many = "Dominion Energy Nuclear Connecticut, Inc.; Millstone Power Station; North Anna Power Station; Surry Power Station; V.C. Summer; Consideration of Approval of Transfer of Licenses"
    assert_equal "License transfer application", p.headline(notice.(many)), "many sites: subject only"
    refute_match(/\.\.\.|…/, p.headline(notice.("Duke Energy Carolinas, LLC; Catawba Nuclear Station, Units 1 and 2, and McGuire Nuclear Station, Units 1 and 2; Exemption")).to_s)
    assert_nil p.headline(notice.("Sunshine Act Meetings"))
  end
end
