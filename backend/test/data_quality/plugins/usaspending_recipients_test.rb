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
    assert_equal "Recipient: SHINE TECHNOLOGIES, LLC\nParent: SHINE TECHNOLOGIES, LLC\nAddress: registered address (SAM registration)\nCity: JANESVILLE\nState: WI\nCountry: USA", Source.find_by!(url: RECORD).content_text
  end

  test "proposes the company's headquarters city and state" do
    crawl
    source = Source.find_by!(url: RECORD)
    claim = plugin.extract(source, nil).sole

    assert_equal({ "hq_city" => "Janesville", "hq_state" => "WI" }, claim[:payload].slice("hq_city", "hq_state"))
    assert plugin.quote_in_source?(source, claim[:quote])
    assert_includes claim[:quote], "registered address (SAM registration)"
    assert_empty plugin.extract(Source.new(content_text: "Recipient: X\nCity: Paris\nState: \nCountry: FRA"), nil)
  end

  test "a block stops the run" do
    stub_request(:get, RECORD).to_return(status: 403, body: "Forbidden")
    assert_equal Plugin::BLOCKED, crawl.stats["stopped"]
  end

  test "a block on USAspending today stops the run before asking" do
    Source.create!(url: "https://api.usaspending.gov/api/v2/search/spending_by_award/", source_kind: "usaspending_api", crawl_status: "blocked", fetched_at: Time.current)
    assert_equal({ "stopped" => Plugin::BLOCKED }, crawl.stats)
    assert_not_requested @record
  end

  test "a failed read is tried again the next day, not in 90" do
    stub_request(:get, RECORD).to_return(status: 503, body: "busy")
    crawl
    assert_nil Source.find_by!(url: RECORD).content_text
    stub_request(:get, RECORD).to_return(body: file_fixture("usaspending/shine_recipient.json").read, headers: { "Content-Type" => "application/json" })
    travel 1.day do
      assert_equal 1, crawl.stats["changed"]
    end
  end

  test "at most PER_NIGHT a day, a same-day rerun included" do
    ids = (1..(Plugin::PER_NIGHT + 3)).map { |i| format("%08d-0000-0000-0000-000000000000-C", i) }
    csv = CSV.generate { |rows| rows << DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS; ids.each { |id| rows << DataQuality::Plugins::UsaspendingDoeAwards::COLUMNS.map { |c| c == "recipient_id" ? id : "x" } } }
    Source.create!(url: "https://www.usaspending.gov/recipient/many/latest", source_kind: "usaspending_doe_awards", content_text: csv, crawl_status: "ok")
    stub_request(:get, %r{/api/v2/recipient/}).to_return(body: file_fixture("usaspending/shine_recipient.json").read)

    assert_equal Plugin::PER_NIGHT, crawl.stats["changed"] + crawl.stats.fetch("unchanged", 0)
    assert_empty crawl.stats.except("stopped"), "the day's quota is used"
  end

  test "no HQ when the company already has one, or when the recipient is under another parent (DQ, 30 Oct)" do
    crawl
    source = Source.find_by!(url: RECORD)
    shine = Organization.create!(name: "SHINE Technologies", hq_city: "Janesville", hq_state: "WI")
    shine.aliases.find_or_create_by!(alias: "SHINE Technologies")
    assert_empty plugin.extract(source, nil), "it has a headquarters already"
    shine.update_columns(hq_city: nil, hq_state: nil)
    assert_equal 1, plugin.extract(source, nil).size

    branch = Source.new(content_text: "Recipient: GE VERNOVA OPERATIONS LLC\nParent: GE VERNOVA INC\nAddress: registered address (SAM registration)\nCity: NISKAYUNA\nState: NY\nCountry: USA")
    assert_empty plugin.extract(branch, nil), "a subsidiary's or branch's address"
  end

  test "a record stored before the parent was kept is read again, in full" do
    crawl
    source = Source.find_by!(url: RECORD)
    source.update_columns(content_text: "Recipient: SHINE TECHNOLOGIES, LLC\nCity: JANESVILLE\nState: WI\nCountry: USA", fetched_at: 2.days.ago, etag: "x")
    crawl
    assert_includes source.reload.content_text, "Parent: SHINE TECHNOLOGIES, LLC"
  end
end
