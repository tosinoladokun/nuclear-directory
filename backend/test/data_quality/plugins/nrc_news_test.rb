require "test_helper"

# NRC refuses the workstation, so this fixture is written in the standard
# RSS 2.0 shape NRC's feed uses (its first production read goes to Data
# Quality before any claim is approved), not fetched.
class DataQuality::Plugins::NrcNewsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcNews
  FEED = Plugin::FEEDS.values.first
  TODAY = Date.new(2026, 10, 28)

  setup do
    stub_request(:get, "https://www.nrc.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /admin/\n")
    stub_request(:get, FEED).to_return(body: file_fixture("nrc_news/rss.xml").read, headers: { "Content-Type" => "application/rss+xml" })
    [ "Kairos Power", Plugin::AGENCY ].each do |name|
      company = Organization.find_by(slug: name.parameterize) || Organization.create!(name:)
      company.aliases.find_or_create_by!(alias: name)
      company.verify!(by: "human:tosin") unless company.verified?
    end
    Organization.find_by!(slug: Plugin::AGENCY.parameterize).aliases.find_or_create_by!(alias: "Nuclear Regulatory Commission")
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY })
  def source = Source.find_by!(url: FEED)

  test "is the plug-in for nrc_news, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_news")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "nrc_news"
  end

  test "a recent release naming a company we have is news about NRC and it; NRC-only and old items aren't" do
    DataQuality::Stages::Crawl.call(plugin:)
    claims = plugin.extract(source, nil)

    assert_equal [ "NRC Issues Construction Permit for Kairos Power Hermes 2 Test Reactor" ], claims.map { |c| c[:quote] }
    payload = claims.first[:payload]
    assert_equal [ "U.S. Nuclear Regulatory Commission", "Kairos Power" ], payload["about"].map { |a| a["name"] }
    assert_equal "U.S. Nuclear Regulatory Commission", payload["publisher"]
    refute payload.key?("lead")
    assert plugin.quote_in_source?(source, claims.first[:quote])
  end
end
