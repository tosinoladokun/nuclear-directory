require "test_helper"

# The answers are shaped from NRC's ADAMS Public Search API guide; the API
# needs a key the workstation doesn't have.
class DataQuality::Plugins::NrcAdamsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcAdams
  TODAY = Date.new(2026, 10, 28)
  ANSWER = { "results" => [ { "document" => { "AccessionNumber" => "ML26290A001", "DocumentTitle" => "Kairos Power - Pre-Application Meeting Summary",
    "DocumentDate" => "2026-10-20", "DocumentType" => [ "Meeting Summary" ], "DocketNumber" => "99902069", "content" => "full text", "Url" => "https://adams-search.nrc.gov/ML26290A001" } } ] }.freeze

  setup do
    stub_request(:get, "https://adams-api.nrc.gov/robots.txt").to_return(status: 404)
    @search = stub_request(:post, Plugin::API_URL).with(headers: { "Ocp-Apim-Subscription-Key" => "k" }).to_return(body: ANSWER.to_json, headers: { "Content-Type" => "application/json" })
  end

  def plugin(key: "k") = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), key:, today: -> { TODAY })
  def crawl(key: "k") = DataQuality::Stages::Crawl.call(plugin: plugin(key:))

  test "is the plug-in for nrc_adams, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_adams")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "nrc_adams"
  end

  test "without a key it does nothing" do
    assert_equal({ "skipped" => Plugin::NO_KEY }, crawl(key: nil).stats)
    assert_not_requested @search
  end

  test "stores each search's documents' catalogue fields once a day, sending the key, proposing nothing" do
    assert_equal Plugin::SEARCHES.size, crawl.stats.values.count("changed")
    assert_equal Plugin::SEARCHES.size, crawl.stats.values.count("skipped_recent")
    assert_requested @search, times: Plugin::SEARCHES.size
    assert_requested(:post, Plugin::API_URL, times: Plugin::SEARCHES.size) { |request| JSON.parse(request.body)["filters"].last["value"] == "(DocumentDate ge '2026-10-14')" }

    source = Source.find_by!(url: "#{Plugin::API_URL}#pre-application")
    row = JSON.parse(source.content_text)
    assert_equal "ML26290A001", row["AccessionNumber"]
    refute row.key?("content"), "never the document's text"
    refute_includes source.content_text, "\"k\""
    assert_empty plugin.extract(source, nil)
  end

  test "a refused request is recorded" do
    stub_request(:post, Plugin::API_URL).to_return(status: 403, body: "Forbidden")
    assert_equal "blocked", crawl.stats.values.first
    assert Source.find_by!(url: "#{Plugin::API_URL}#pre-application").crawl_blocked?
  end

  test "robots' refusal needs a person at once; repeated blocks too" do
    stub_request(:get, "https://adams-api.nrc.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /\n")
    crawl
    assert Source.find_by!(url: "#{Plugin::API_URL}#pre-application").crawl_needs_human?
  end

  test "documents with unexpected fields keep their field names" do
    stub_request(:post, Plugin::API_URL).to_return(body: { "results" => [ { "accessionNumber" => "ML1" } ] }.to_json)
    crawl
    assert_equal({ "unexpected_fields" => [ "accessionNumber" ] }, JSON.parse(Source.find_by!(url: "#{Plugin::API_URL}#pre-application").content_text))
  end
end
