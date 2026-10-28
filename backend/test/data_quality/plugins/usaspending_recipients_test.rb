require "test_helper"

# The fixture is SHINE Technologies' real USAspending recipient record,
# fetched 2026-10-29 with the plug-in's user agent.
class DataQuality::Plugins::UsaspendingRecipientsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::UsaspendingRecipients
  ID = "a0d3a9bd-ad2a-3c7c-aee7-9927987aee51-C".freeze
  RECORD = format(Plugin::API_URL, ID).freeze

  setup do
    stub_request(:get, "https://api.usaspending.gov/robots.txt").to_return(status: 404)
    @record = stub_request(:get, RECORD).to_return(body: file_fixture("usaspending/shine_recipient.json").read, headers: { "Content-Type" => "application/json" })
    csv = CSV.generate { |rows| rows << DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS; rows << DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS.map { |c| c == "recipient_id" ? ID : (c == "recipient_name" ? "SHINE TECHNOLOGIES, LLC" : "x") } }
    Source.create!(url: "https://www.usaspending.gov/recipient/#{ID}/latest", source_kind: "usaspending_doe_awards", content_text: csv, crawl_status: "ok")
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)

  test "is the plug-in for usaspending_recipients, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("usaspending_recipients")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "usaspending_recipients"
  end

  test "reads each stored recipient's record once, keeping only its name and address's city, state and country" do
    assert_equal({ "changed" => 1 }, crawl.stats)
    assert_equal({}, crawl.stats)
    assert_requested @record, times: 1
    assert_equal "Recipient: SHINE TECHNOLOGIES, LLC\nCity: JANESVILLE\nState: WI\nCountry: USA", Source.find_by!(url: RECORD).content_text
  end

  test "proposes the company's headquarters city and state" do
    crawl
    source = Source.find_by!(url: RECORD)
    claim = plugin.extract(source, nil).sole

    assert_equal({ "hq_city" => "Janesville", "hq_state" => "WI" }, claim[:payload].slice("hq_city", "hq_state"))
    assert plugin.quote_in_source?(source, claim[:quote])
    assert_empty plugin.extract(Source.new(content_text: "Recipient: X\nCity: Paris\nState: \nCountry: FRA"), nil)
  end

  test "a block stops the run" do
    stub_request(:get, RECORD).to_return(status: 403, body: "Forbidden")
    assert_equal Plugin::BLOCKED, crawl.stats["stopped"]
  end
end
