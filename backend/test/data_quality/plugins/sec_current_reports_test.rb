require "test_helper"

# The fixture follows the columns of SEC's submissions API (filings.recent),
# written for the test: SEC isn't fetched from the workstation.
class DataQuality::Plugins::SecCurrentReportsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::SecCurrentReports
  Company = Data.define(:id, :name, :sec_cik)
  Directory = Data.define(:organizations_with_sec_cik)
  LIST = "https://data.sec.gov/submissions/CIK0001849056.json".freeze
  TODAY = Date.new(2026, 10, 28)

  setup do
    stub_request(:get, "https://data.sec.gov/robots.txt").to_return(status: 404)
    @list = stub_request(:get, LIST).to_return(body: file_fixture("sec_8k/submissions.json").read, headers: { "Content-Type" => "application/json" })
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY },
    directory: Directory.new(organizations_with_sec_cik: [ Company.new(id: 1, name: "Oklo", sec_cik: "0001849056") ]))
  def source = Source.find_by!(url: "#{LIST}#8-K")

  test "is the plug-in for sec_current_reports, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("sec_current_reports")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "sec_current_reports"
  end

  test "stores the recent 8-Ks reporting a deal item, once a day" do
    assert_equal({ "changed" => 1 }, DataQuality::Stages::Crawl.call(plugin:).stats)
    assert_equal({ "skipped_recent" => 1 }, DataQuality::Stages::Crawl.call(plugin:).stats)
    assert_requested @list, times: 1
    assert_equal [ "Company: Oklo",
      "form: 8-K | filed: 2026-10-14 | items: 1.01, 9.01 | document: https://www.sec.gov/Archives/edgar/data/1849056/000184905626000101/oklo-20261014.htm",
      "form: 8-K/A | filed: 2026-08-20 | items: 3.02 | document: https://www.sec.gov/Archives/edgar/data/1849056/000184905626000070/oklo-20260820.htm" ],
      source.content_text.lines(chomp: true)
  end

  test "each becomes news about the company, linked to the filing" do
    DataQuality::Stages::Crawl.call(plugin:)
    first = plugin.extract(source, nil).first

    assert_equal "Oklo 8-K: Entry into a Material Definitive Agreement", first[:payload]["title"]
    assert_equal "2026-10-14", first[:payload]["published_on"]
    assert_equal [ { "name" => "Oklo", "type" => "organization" } ], first[:payload]["about"]
    assert_match "/000184905626000101/oklo-20261014.htm", first[:payload]["url"]
    assert plugin.quote_in_source?(source, first[:quote])
  end

  test "a block stops the run" do
    stub_request(:get, LIST).to_return(status: 403, body: "Forbidden")
    assert_equal Plugin::BLOCKED, DataQuality::Stages::Crawl.call(plugin:).stats["stopped"]
  end
end
