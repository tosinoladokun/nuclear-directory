require "test_helper"

# The fixture is the Office of Nuclear Energy's real news feed (10 items),
# fetched 2026-10-26 with the plug-in's user agent.
class DataQuality::Plugins::DoeNuclearNewsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::DoeNuclearNews
  FEED = Plugin::FEEDS.values.first
  TODAY = Date.new(2026, 10, 26)

  setup do
    stub_request(:get, "https://www.energy.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /admin/\n")
    stub_request(:get, FEED).to_return(body: file_fixture("doe_ne/rss.xml").read, headers: { "Content-Type" => "application/rss+xml" })
    [ "Westinghouse", "Natura Resources" ].each do |name|
      company = Organization.find_by(slug: name.parameterize) || Organization.create!(name:)
      company.update!(name:)
      company.aliases.find_or_create_by!(alias: name)
      company.verify!(by: "human:tosin") unless company.verified?
    end
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY })
  def source = Source.find_by!(url: FEED)

  test "is the plug-in for doe_nuclear_news, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("doe_nuclear_news")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "doe_nuclear_news"
  end

  test "an item naming only DOE's own office isn't proposed" do
    doe = Organization.find_by(name: "U.S. Department of Energy") || Organization.create!(name: "U.S. Department of Energy")
    doe.verify!(by: "human:tosin") unless doe.verified?
    doe.aliases.find_or_create_by!(alias: "U.S. Department of Energy")
    doe.aliases.find_or_create_by!(alias: "Office of Nuclear Energy")
    DataQuality::Stages::Crawl.call(plugin:)

    titles = plugin.extract(source, nil).map { |c| c[:quote] }
    refute_includes titles, "DOE Office of Nuclear Energy Announces $50M in Funding to Revolutionize Reactor Cladding Material"
    assert_includes titles, "Department of Energy Provides Rare Salt Material to Natura Resources"
  end

  test "each recent announcement naming a company we have is news about DOE and that company, never a lead" do
    DataQuality::Stages::Crawl.call(plugin:)
    claims = plugin.extract(source, nil)

    titles = claims.map { |c| c[:quote] }
    assert_equal [ "Department of Energy Provides Rare Salt Material to Natura Resources", "Westinghouse eVinci Microreactor Achieves Criticality Milestone" ], titles, "newest first"
    natura = claims.find { |c| c[:quote].include?("Natura") }[:payload]
    assert_equal [ "U.S. Department of Energy", "Natura Resources" ], natura["about"].map { |a| a["name"] }
    assert_equal "U.S. Department of Energy, Office of Nuclear Energy", natura["publisher"]
    assert claims.none? { |c| c[:payload].key?("lead") }
    assert claims.all? { |c| plugin.quote_in_source?(source, c[:quote]) }
    assert_match "DOE's own announcement", plugin.source_facts(source)
  end
end
