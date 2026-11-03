require "test_helper"

class DataQuality::Plugins::SecTickerCiksTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::SecTickerCiks
  LIST = { "0" => { "cik_str" => 1_018_724, "ticker" => "AMZN", "title" => "AMAZON COM INC" },
    "1" => { "cik_str" => 1_849_056, "ticker" => "OKLO", "title" => "Oklo Inc." } }.to_json

  setup do
    Source.create!(url: Plugin::TICKERS_URL, source_kind: "sec_submissions", crawl_status: "ok", content_text: LIST)
    @amazon = Organization.create!(name: "Amazon", exchange: "NASDAQ", ticker: "AMZN", verification_status: "verified", verified_by: "human:tosin")
    @amazon.aliases.find_or_create_by!(alias: "Amazon")
    Organization.create!(name: "Toronto Uranium", exchange: "TSX", ticker: "OKLO", verification_status: "verified", verified_by: "human:tosin")
  end

  def plugin = Plugin.new

  test "is the plug-in for sec_ticker_ciks, and runs nightly after Form D" do
    assert_instance_of Plugin, DataQuality::Plugin.for("sec_ticker_ciks")
    kinds = DataQuality::DailyCrawlJob::SOURCE_KINDS
    assert_operator kinds.index("sec_ticker_ciks"), :>, kinds.index("sec_form_d")
  end

  test "a US-listed company without a CIK gets the CIK the SEC list gives its exact ticker, quoting the entry" do
    assert_equal({ "stored" => 1 }, DataQuality::Stages::Crawl.call(plugin:).stats)
    source = Source.find_by!(url: "#{Plugin::TICKERS_URL}#AMZN")
    claim = plugin.extract(source, nil).sole

    assert_equal({ "name" => "Amazon", "sec_cik" => "0001018724" }, claim[:payload])
    assert plugin.quote_in_source?(source, claim[:quote])
    assert_includes claim[:quote], "AMAZON COM INC"
    refute Source.exists?(url: "#{Plugin::TICKERS_URL}#OKLO"), "a TSX listing isn't matched to an SEC ticker"
  end

  test "once the company has its CIK, nothing more is proposed" do
    DataQuality::Stages::Crawl.call(plugin:)
    @amazon.update_columns(sec_cik: "0001018724")
    assert_empty plugin.extract(Source.find_by!(url: "#{Plugin::TICKERS_URL}#AMZN"), nil)
  end
end
