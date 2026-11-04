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

  test "nothing is read from a ticker list whose last fetch failed" do
    Source.find_by!(url: Plugin::TICKERS_URL).update_columns(crawl_status: "blocked", status_reason: "HTTP 403")
    assert_match "last read failed", DataQuality::Stages::Crawl.call(plugin:).stats["ticker list"]
  end

  test "a ticker the list no longer gives once: its entry stops and its waiting claims go to a person" do
    DataQuality::Stages::Crawl.call(plugin:)
    source = Source.find_by!(url: "#{Plugin::TICKERS_URL}#AMZN")
    claim = Candidate.create!(source:, kind: "organization", status: "new", quote: source.content_text, payload: { "name" => "Amazon", "sec_cik" => "0001018724" })
    Source.find_by!(url: Plugin::TICKERS_URL).update_columns(content_text: { "0" => { "cik_str" => 1, "ticker" => "OTHER", "title" => "X" } }.to_json)

    assert_equal 1, DataQuality::Stages::Crawl.call(plugin:).stats["withdrawn"]
    assert source.reload.crawl_needs_human?
    assert claim.reload.status_needs_review?
  end

  test "a CIK already on another record: no claim (it would land there), counted for a person" do
    Organization.create!(name: "Amazon Duplicate", sec_cik: "0001018724")
    stats = DataQuality::Stages::Crawl.call(plugin:).stats
    assert_equal 1, stats["CIK already on another record"]
    refute Source.exists?(url: "#{Plugin::TICKERS_URL}#AMZN")
  end

  test "a ticker two directory companies share is no one's; a withdrawn entry back unchanged is read again" do
    Organization.create!(name: "Amazon Twin", exchange: "NYSE", ticker: "AMZN", verification_status: "verified", verified_by: "human:tosin")
    assert_equal 2, DataQuality::Stages::Crawl.call(plugin:).stats["ticker on several companies"], "both companies"
    Organization.find_by!(name: "Amazon Twin").destroy

    DataQuality::Stages::Crawl.call(plugin:)
    source = Source.find_by!(url: "#{Plugin::TICKERS_URL}#AMZN")
    source.update_columns(crawl_status: "needs_human")
    DataQuality::Stages::Crawl.call(plugin:)
    assert source.reload.crawl_ok?
  end

  test "a company whose ticker changed: its old entry is withdrawn while a claim is open" do
    DataQuality::Stages::Crawl.call(plugin:)
    source = Source.find_by!(url: "#{Plugin::TICKERS_URL}#AMZN")
    claim = Candidate.create!(source:, kind: "organization", status: "new", quote: source.content_text, payload: { "name" => "Amazon", "sec_cik" => "0001018724" },
      ai_recommendation: "recommend_publish")
    @amazon.update_columns(ticker: "AMZX")
    assert_equal 1, DataQuality::Stages::Crawl.call(plugin:).stats["withdrawn"]
    claim.reload
    assert claim.status_needs_review?
    assert_nil claim.ai_recommendation
  end
end
