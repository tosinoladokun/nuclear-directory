require "test_helper"

# Fixtures: New Era's real filing list (cut to its Form D and two other
# filings) and two real Form D notices, fetched 2026-10-19 and 22 with the
# Fetcher's user agent, with the people they name (related persons,
# signatures) and the phone number removed.
class DataQuality::Plugins::SecFormDTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::SecFormD
  BY = "human:tosin".freeze
  LIST = "https://data.sec.gov/submissions/CIK0002028336.json".freeze
  NOTICE = "https://www.sec.gov/Archives/edgar/data/2028336/000202833624000006/primary_doc.xml".freeze

  setup do
    stub_request(:get, "https://data.sec.gov/robots.txt").to_return(status: 404)
    stub_request(:get, "https://www.sec.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /cgi-bin\n")
    @list = stub_request(:get, LIST).to_return(body: file_fixture("sec_form_d/newera_submissions.json").read, headers: { "Content-Type" => "application/json" })
    @tickers = stub_request(:get, Plugin::TICKERS_URL).to_return(body: { "0" => { cik_str: 2028336, ticker: "NUAI", title: "New Era Energy & Digital, Inc." } }.to_json)
    @notice = stub_request(:get, NOTICE).to_return(body: file_fixture("sec_form_d/newera_d.xml").read, headers: { "Content-Type" => "text/xml" })
    @company = Organization.create!(name: "New Era Energy & Digital", sec_cik: "0002028336").tap { |c| c.verify!(by: BY); c.aliases.create!(alias: c.name) }
  end

  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def notice_source = Source.find_by!(url: NOTICE)

  def filing(accession, form: "D", sold: "$10,000,000", amends: "-", combination: "no", clarification: "-", filed: "2025-01-02")
    line = "form: #{form} | filed: #{filed} | accession: #{accession} | issuer CIK: 0002028336 | issuer: NEW ERA HELIUM INC. | " \
      "industry group: Oil and Gas | securities: equity | first sale: 2024-12-06 | amount offered: $20,000,000 | amount sold: #{sold} | " \
      "amends: #{amends} | business combination: #{combination} | clarification: #{clarification}"
    Source.create!(url: "https://www.sec.gov/Archives/edgar/data/2028336/#{accession.delete('-')}/primary_doc.xml", source_kind: "sec_form_d",
      crawl_status: "ok", content_text: line, content_sha256: Digest::SHA256.hexdigest(line))
  end

  test "is the plug-in for sec_form_d" do
    assert_instance_of Plugin, DataQuality::Plugin.for("sec_form_d")
  end

  test "reads each company's filing list once a day and stores each Form D once, as its offering fields only" do
    run = crawl
    second = crawl

    assert_equal({ "ticker list" => "changed", "lists changed" => 1, "filings new" => 1 }, run.stats)
    assert_equal({ "ticker list" => "skipped_recent", "lists skipped_recent" => 1, "filings stored_before" => 1 }, second.stats)
    assert_requested @tickers, times: 1
    assert_match "NUAI", Source.find_by!(url: Plugin::TICKERS_URL).content_text, "kept for Data Quality to cite a CIK by ticker"
    assert_requested @list, times: 1
    assert_requested @notice, times: 1
    assert_equal "form: D | filed: 2024-12-19 | accession: 0002028336-24-000006 | issuer CIK: 0002028336 | issuer: NEW ERA HELIUM INC. | " \
      "industry group: Oil and Gas | securities: equity, debt, options | first sale: 2024-12-06 | amount offered: $105,000,000 | " \
      "amount sold: $37,000,000 | amends: - | business combination: no | clarification: -", notice_source.content_text
    assert_equal Date.new(2024, 12, 19), notice_source.published_on
    assert_equal "D\t0002028336-24-000006\t2024-12-19\txslFormDX01/primary_doc.xml", Source.find_by!(url: LIST).content_text, "only Form D filings are kept"
  end

  test "a block on the ticker list stops the crawl before any filing list" do
    stub_request(:get, Plugin::TICKERS_URL).to_return(status: 403, body: "Your request has been identified as part of a network of automated tools")

    assert_equal "SEC blocked us", crawl.stats["stopped"]
    assert_not_requested @list
  end

  test "a block stops the crawl" do
    stub_request(:get, LIST).to_return(status: 403, body: "Your request has been identified as part of a network of automated tools")

    assert_equal "SEC blocked us", crawl.stats["stopped"]
    assert Source.find_by!(url: LIST).crawl_blocked?
  end

  test "a filing is a funding round on its company, by its CIK" do
    crawl
    candidates = plugin.extract(notice_source, nil)

    assert_equal [ { kind: "deal_term", quote: notice_source.content_text, payload: {
      "organization" => { "name" => "NEW ERA HELIUM INC.", "sec_cik" => "0002028336" }, "link_type" => "Organization",
      "term_type" => "funding_round", "external_id" => "0002028336-24-000006", "amount_usd" => "37000000.0",
      "starts_on" => "2024-12-06", "amount_offered_usd" => "105000000.0" } } ], candidates
    assert plugin.quote_in_source?(notice_source, candidates.sole[:quote])
    refute_match(/relatedPerson|signature/i, notice_source.content_text)
  end

  test "crawl to match: the round lands pending on the company its CIK names, under another name" do
    DataQuality::Pipeline.run("sec_form_d", plugin:, only: %w[crawl extract match])

    claim = Candidate.sole
    term = DealTerm.find(claim.subject_id)
    assert_equal [ @company, "funding_round", 37_000_000, "pending" ], [ term.link, term.term_type, term.amount_usd, term.verification_status ]
  end

  test "a D/A lands on its round's first filing, and only the latest filing of a round is proposed" do
    original = filing("0002028336-25-000001")
    first = filing("0002028336-25-000002", form: "D/A", sold: "$12,000,000", amends: "0002028336-25-000001")
    latest = filing("0002028336-25-000003", form: "D/A", sold: "$15,000,000", amends: "0002028336-25-000002")

    assert_empty plugin.extract(original, nil)
    assert_empty plugin.extract(first, nil)
    assert_equal [ "0002028336-25-000001", "15000000.0" ], plugin.extract(latest, nil).sole[:payload].values_at("external_id", "amount_usd")
  end

  test "two D/As amending the same filing: only the newest is proposed" do
    original = filing("0002028336-25-000001")
    february = filing("0002028336-25-000002", form: "D/A", sold: "$12,000,000", amends: "0002028336-25-000001", filed: "2025-02-01")
    march = filing("0002028336-25-000003", form: "D/A", sold: "$15,000,000", amends: "0002028336-25-000001", filed: "2025-03-01")

    assert_empty plugin.extract(original, nil)
    assert_empty plugin.extract(february, nil)
    assert_equal [ "0002028336-25-000001", "15000000.0" ], plugin.extract(march, nil).sole[:payload].values_at("external_id", "amount_usd")
  end

  test "a filing that failed is recorded, and isn't asked for again the same day" do
    stub_request(:get, NOTICE).to_return(status: 500, body: "oops")

    assert_equal 1, crawl.stats["filings error"]
    assert_equal 1, crawl.stats["filings skipped_recent"]
    assert_requested :get, NOTICE, times: 1
    assert_match "500", notice_source.status_reason
    assert_empty plugin.extract(notice_source, nil)
  end

  test "older filing lists are read too, so a round's first filing there is found" do
    list = JSON.parse(file_fixture("sec_form_d/newera_submissions.json").read)
    list["filings"]["recent"] = { "form" => [ "D/A" ], "accessionNumber" => [ "0002028336-25-000009" ], "filingDate" => [ "2025-06-01" ], "primaryDocument" => [ "primary_doc.xml" ] }
    list["filings"]["files"] = [ { "name" => "CIK0002028336-submissions-001.json" } ]
    stub_request(:get, LIST).to_return(body: list.to_json)
    older = stub_request(:get, "https://data.sec.gov/submissions/CIK0002028336-submissions-001.json").to_return(body: {
      form: [ "D" ], accessionNumber: [ "0002028336-24-000006" ], filingDate: [ "2024-12-19" ], primaryDocument: [ "primary_doc.xml" ] }.to_json)
    amendment = file_fixture("sec_form_d/newera_d.xml").read.sub("<isAmendment>false</isAmendment>",
      "<isAmendment>true</isAmendment><previousAccessionNumber>0002028336-24-000006</previousAccessionNumber>").sub("37000000", "40000000")
    stub_request(:get, "https://www.sec.gov/Archives/edgar/data/2028336/000202833625000009/primary_doc.xml").to_return(body: amendment)

    assert_equal 2, crawl.stats["filings new"]
    assert_requested older, times: 1
    amended = Source.find_by!(url: "https://www.sec.gov/Archives/edgar/data/2028336/000202833625000009/primary_doc.xml")
    assert_equal [ "0002028336-24-000006", "40000000.0" ], plugin.extract(amended, nil).sole[:payload].values_at("external_id", "amount_usd")
    assert_empty plugin.extract(notice_source, nil), "the original is superseded"
  end

  test "a later filing withdraws the round's earlier claim still waiting, on a later run" do
    DataQuality::Pipeline.run("sec_form_d", plugin:, only: %w[crawl extract match])
    earlier = Candidate.sole
    assert earlier.status_matched?

    list = JSON.parse(file_fixture("sec_form_d/newera_submissions.json").read)
    %w[form accessionNumber filingDate primaryDocument].zip([ "D/A", "0002028336-25-000009", "2025-06-01", "primary_doc.xml" ]).each { |key, value| list["filings"]["recent"][key].unshift(value) }
    stub_request(:get, LIST).to_return(body: list.to_json)
    amendment = file_fixture("sec_form_d/newera_d.xml").read.sub("<isAmendment>false</isAmendment>",
      "<isAmendment>true</isAmendment><previousAccessionNumber>0002028336-24-000006</previousAccessionNumber>").sub("37000000", "40000000")
    stub_request(:get, "https://www.sec.gov/Archives/edgar/data/2028336/000202833625000009/primary_doc.xml").to_return(body: amendment)
    Source.update_all(fetched_at: 2.days.ago)

    DataQuality::Pipeline.run("sec_form_d", plugin:, only: %w[crawl extract match])

    assert earlier.reload.status_rejected?
    assert_match "Superseded", earlier.notes
    later = Candidate.where.not(id: earlier.id).sole
    assert_equal [ earlier.subject_id, "40000000.0" ], [ later.subject_id, later.payload["amount_usd"] ]
  end

  test "a same-day rerun after a block requests nothing more" do
    stub_request(:get, NOTICE).to_return(status: 403, body: "Your request has been identified as part of a network of automated tools")
    first = crawl
    assert_equal "SEC blocked us", first.stats["stopped"]

    second = crawl
    assert_equal "SEC blocked us", second.stats["stopped"]
    assert_requested :get, NOTICE, times: 1
  end

  test "an original that arrives after its amendments has the whole chain read again" do
    a = filing("0002028336-25-000001")
    b = filing("0002028336-25-000002", form: "D/A", amends: "0002028336-25-000001")
    c = filing("0002028336-25-000003", form: "D/A", amends: "0002028336-25-000002")
    [ a, b, c ].each { |source| source.update_columns(extracted_sha256: source.content_sha256) }

    plugin.send(:reread_amendments, Plugin::Filing.new(form: "D", accession: "0002028336-25-000001", filed_on: "2025-01-02", document: "x"), @company)

    assert_equal [ a.content_sha256, nil, nil ], [ a, b, c ].map { |source| source.reload.extracted_sha256 }
  end

  test "an Indefinite amount offered is stated as nil, so it clears an earlier one" do
    amendment = filing("0002028336-25-000004", form: "D/A", amends: "0002028336-25-000001").tap do |source|
      line = source.content_text.sub("amount offered: $20,000,000", "amount offered: Indefinite")
      source.update!(content_text: line)
    end
    payload = plugin.extract(amendment, nil).sole[:payload]
    assert payload.key?("amount_offered_usd")
    assert_nil payload["amount_offered_usd"]
  end

  test "a D/A reporting nothing sold sends the round's earlier claim to a person, not away" do
    DataQuality::Pipeline.run("sec_form_d", plugin:, only: %w[crawl extract match])
    earlier = Candidate.sole
    list = JSON.parse(file_fixture("sec_form_d/newera_submissions.json").read)
    %w[form accessionNumber filingDate primaryDocument].zip([ "D/A", "0002028336-25-000009", "2025-06-01", "primary_doc.xml" ]).each { |key, value| list["filings"]["recent"][key].unshift(value) }
    stub_request(:get, LIST).to_return(body: list.to_json)
    zero = file_fixture("sec_form_d/newera_d.xml").read.sub("<isAmendment>false</isAmendment>",
      "<isAmendment>true</isAmendment><previousAccessionNumber>0002028336-24-000006</previousAccessionNumber>").sub("<totalAmountSold>37000000", "<totalAmountSold>0")
    stub_request(:get, "https://www.sec.gov/Archives/edgar/data/2028336/000202833625000009/primary_doc.xml").to_return(body: zero)
    Source.update_all(fetched_at: 2.days.ago)
    crawl

    assert earlier.reload.status_needs_review?
    assert_match "nothing sold", earlier.notes
  end

  test "an approved round whose D/A reports nothing sold gets one review item; its decision stands" do
    DataQuality::Pipeline.run("sec_form_d", plugin:, only: %w[crawl extract match])
    original = Candidate.sole
    assert DataQuality::Review.approve([ original.id ], by: "human:tosin").sole.ok?
    list = JSON.parse(file_fixture("sec_form_d/newera_submissions.json").read)
    %w[form accessionNumber filingDate primaryDocument].zip([ "D/A", "0002028336-25-000009", "2025-06-01", "primary_doc.xml" ]).each { |key, value| list["filings"]["recent"][key].unshift(value) }
    stub_request(:get, LIST).to_return(body: list.to_json)
    zero = file_fixture("sec_form_d/newera_d.xml").read.sub("<isAmendment>false</isAmendment>",
      "<isAmendment>true</isAmendment><previousAccessionNumber>0002028336-24-000006</previousAccessionNumber>").sub("<totalAmountSold>37000000", "<totalAmountSold>0")
    stub_request(:get, "https://www.sec.gov/Archives/edgar/data/2028336/000202833625000009/primary_doc.xml").to_return(body: zero)
    Source.update_all(fetched_at: 2.days.ago)
    2.times { crawl }

    assert original.reload.status_merged?, "the decision stands"
    flags = Candidate.where(review_origin: "dropped", subject_id: original.subject_id)
    assert_equal 1, flags.count, "once, not every night"
    assert_match "nothing sold", flags.sole.notes
  end

  test "a clarification only under use of proceeds is kept, and holds the round" do
    xml = file_fixture("sec_form_d/newera_d.xml").read.sub(%r{(<useOfProceeds>.*?<clarificationOfResponse>)(</clarificationOfResponse>)}m, '\\1Part of the proceeds repays a bridge loan.\\2')
    stub_request(:get, NOTICE).to_return(body: xml)
    crawl

    assert_match "clarification: Part of the proceeds repays a bridge loan.", notice_source.content_text
    assert_match "bridge loan", plugin.hold_for_review(Candidate.new(kind: "deal_term", quote: notice_source.content_text))
  end

  test "a D/A whose original isn't stored is the round of the filing it names" do
    amendment = filing("0002028336-25-000005", form: "D/A", amends: "0001012975-25-000531")

    assert_equal "0001012975-25-000531", plugin.extract(amendment, nil).sole[:payload]["external_id"]
  end

  test "nothing sold, or an indefinite amount, proposes no round" do
    assert_empty plugin.extract(filing("0002028336-25-000006", sold: "$0"), nil)
    assert_empty plugin.extract(filing("0002028336-25-000007", sold: "Indefinite"), nil)
  end

  test "a business combination or a clarification note is held for a person" do
    combination = Candidate.new(kind: "deal_term", quote: filing("0002028336-25-000008", combination: "yes").content_text)
    clarified = Candidate.new(kind: "deal_term", quote: filing("0002028336-25-000009", clarification: "Issued per emergence from chapter 11.").content_text)
    plain = Candidate.new(kind: "deal_term", quote: filing("0002028336-25-000010").content_text)

    assert_match "business combination", plugin.hold_for_review(combination)
    assert_match "chapter 11", plugin.hold_for_review(clarified)
    assert_nil plugin.hold_for_review(plain)
  end

  test "a notice's clarification is kept in its line (Talen, 2023)" do
    stub_request(:get, "https://data.sec.gov/submissions/CIK0001622536.json").to_return(body: {
      filings: { recent: { form: [ "D" ], accessionNumber: [ "0001209191-23-032563" ], filingDate: [ "2023-05-26" ], primaryDocument: [ "primary_doc.xml" ] } }
    }.to_json)
    stub_request(:get, "https://www.sec.gov/Archives/edgar/data/1622536/000120919123032563/primary_doc.xml").to_return(body: file_fixture("sec_form_d/talen_d.xml").read)
    Organization.create!(name: "Talen Energy", sec_cik: "0001622536").verify!(by: BY)

    crawl
    line = Source.find_by!(url: "https://www.sec.gov/Archives/edgar/data/1622536/000120919123032563/primary_doc.xml").content_text

    assert_match "amount sold: $1,377,893,984", line
    assert_match "clarification: Issued in transactions exempt from registration", line
  end
end
