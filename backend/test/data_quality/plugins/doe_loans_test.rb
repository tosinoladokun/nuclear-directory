require "test_helper"

# The fixtures are DOE's real Palisades and Crane Restart loan pages,
# fetched 2026-10-26 with the plug-in's user agent and cut to their title,
# summary and Project Statistics table.
class DataQuality::Plugins::DoeLoansTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::DoeLoans
  PALISADES = "https://www.energy.gov/edf/palisades".freeze
  CRANE = "https://www.energy.gov/edf/crane-restart".freeze

  setup do
    stub_request(:get, "https://www.energy.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /admin/\n")
    stub_request(:get, PALISADES).to_return(body: file_fixture("doe_loans/palisades.html").read)
    stub_request(:get, CRANE).to_return(body: file_fixture("doe_loans/crane-restart.html").read)
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)

  test "is the plug-in for doe_loans, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("doe_loans")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "doe_loans"
  end

  test "stores each page's Project Statistics as lines, once a day" do
    assert_equal({ "Palisades" => "changed", "Crane Restart" => "changed" }, crawl.stats)
    assert_equal({ "Palisades" => "skipped_recent", "Crane Restart" => "skipped_recent" }, crawl.stats)
    text = Source.find_by!(url: CRANE).content_text
    assert_includes text, "Owners: Constellation Energy Generation, LLC"
    assert_includes text, "Loan Amount: $1.0 billion"
    assert_includes text, "Issuance Date: November 2025"
    refute_match(/Jobs/, text)
  end

  test "a research page already at the URL is taken over, keeping its fetch date" do
    old = Source.create!(url: CRANE, source_kind: "web_page", content_text: "<html>old</html>", etag: "x", fetched_at: 1.day.ago)
    crawl
    old.reload
    assert_equal "doe_loans", old.source_kind
    assert_includes old.content_text, "Owners: Constellation Energy Generation, LLC"
  end

  test "a page without the table needs a person" do
    stub_request(:get, PALISADES).to_return(body: "<html><main><h1>Palisades</h1><p>Moved.</p></main></html>")

    assert_equal "needs_human", crawl.stats["Palisades"]
    assert Source.find_by!(url: PALISADES).crawl_needs_human?
  end

  test "the borrower and DOE's funds link, described as the page states the loan" do
    crawl
    source = Source.find_by!(url: PALISADES)
    company, link, term = plugin.extract(source, nil)

    assert_equal({ "name" => "Holtec Palisades, LLC" }, company[:payload])
    assert_equal [ "U.S. Department of Energy", "Holtec Palisades, LLC", "funds" ],
      [ link[:payload].dig("from_organization", "name"), link[:payload].dig("to_organization", "name"), link[:payload]["relationship_type"] ]
    refute link[:payload].key?("description"), "the loan is its term; an existing link's description stays (DQ, 29 Oct)"
    assert [ company, link ].all? { |claim| plugin.quote_in_source?(source, claim[:quote]) }
    assert_equal "Owners: Holtec Palisades, LLC\nLoan Program: Energy Dominance Financing Program\nLoan Amount: $1.52 Billion\nIssuance Date: September 2024", link[:quote]
    refute plugin.quote_in_source?(source, "Owners: Holtec Palisades, LLC\nLoan Amount: $9 Billion")
    assert_equal [ "loan", "1520000000", "Energy Dominance Financing Program", PALISADES, "Holtec Palisades, LLC" ],
      [ *term[:payload].values_at("term_type", "amount_usd", "program", "external_id"), term[:payload].dig("to_organization", "name") ]
    assert plugin.quote_in_source?(source, term[:quote])
  end

  test "an amount not in millions or billions proposes the company and link but no term" do
    crawl
    source = Source.find_by!(url: PALISADES)
    source.update_columns(content_text: source.content_text.sub("$1.52 Billion", "$1.52"))
    claims = plugin.extract(source, nil)
    assert_equal %w[organization relationship], claims.map { |c| c[:kind] }
    assert_equal "Loan of $1.52, under the Energy Dominance Financing Program, closed September 2024", claims.last[:payload]["description"]
  end

  test "a page extracted before loan terms is extracted again" do
    crawl
    source = Source.find_by!(url: PALISADES)
    source.update_columns(extracted_sha256: source.content_sha256, extracted_rows_sha256: source.content_sha256, fetched_at: 1.day.ago)
    crawl
    assert_nil source.reload.extracted_sha256
    DataQuality::Stages::Extract.call(plugin:)
    assert_equal plugin.rows_sha256(source.reload), source.extracted_rows_sha256
  end
end
