require "test_helper"

# Enrich (#479): a requested company's own pages, read against the field
# list; only values in their quotes, quotes on the page, keys from the lists.
class DataQuality::Plugins::CompanyPagesTest < ActiveSupport::TestCase
  HOME = "https://www.acmefission.com/".freeze
  # How the page is stored, and so keyed: a bare homepage without its slash (#670).
  HOME_KEY = HOME.chomp("/").freeze
  ABOUT = "https://www.acmefission.com/about".freeze
  PAGE = <<~HTML.freeze
    <html><body><nav><a href="/about">About us</a><a href="/careers">Careers</a><a href="https://other.com/about">Elsewhere</a></nav>
    <p>Acme Fission Inc. designs small modular reactors.</p><p>Headquartered in Austin, Texas.</p><p>Founded in 2019.</p>
    <p>A world-leading innovator.</p></body></html>
  HTML

  FakeLLM = Struct.new(:data) do
    def structured(**) = DataQuality::OpenRouter::Client::Response.new(data:, model: "fake", usage: {})
  end

  setup do
    Role.create!(key: "reactor_vendor", name: "Reactor developer")
    Technology.create!(key: "smr", name: "Small modular reactor")
    @company = Organization.create!(name: "Acme Fission", website: HOME, domain: "acmefission.com", verification_status: "verified", verified_by: "human:tosin")
    stub_request(:get, "https://www.acmefission.com/robots.txt").to_return(status: 404)
    stub_request(:get, HOME).to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
    stub_request(:get, ABOUT).to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
  end

  test "crawl reads only requested companies: the home page and its own about page, then marks it read" do
    stats = DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    assert_equal({ "companies" => 0, "pages" => 0 }, stats)

    @company.update_columns(enrich_requested_at: Time.current)
    stats = DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    assert_equal({ "companies" => 1, "pages" => 2 }, stats)
    assert_equal %w[company_pages company_pages], Source.where(url: [ HOME, ABOUT ]).pluck(:source_kind)
    assert_not_requested :get, "https://other.com/about"
    assert @company.reload.enriched_at
    assert_equal({ "companies" => 0, "pages" => 0 }, DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil), "read once per request")
  end

  test "extract keeps only values in their quotes and quotes on the page; drops marketing, people and unknown keys" do
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    found = {
      "description" => { "value" => "Acme Fission Inc. designs small modular reactors.", "quote" => "Acme Fission Inc. designs small modular reactors." },
      "hq_city" => { "value" => "Austin", "quote" => "Headquartered in Austin, Texas." },
      "hq_state" => { "value" => "TX", "quote" => "Headquartered in Austin, Texas." }, # not in the quote: dropped
      "founded_year" => { "value" => "2019", "quote" => "Founded in 2019." },
      "legal_name" => { "value" => "Acme Fission Inc.", "quote" => "Acme Fission Inc. is a reactor company." }, # quote not on the page
      "roles" => [ { "key" => "reactor_vendor", "quote" => "designs small modular reactors" }, { "key" => "ceo", "quote" => "Founded in 2019." } ],
      "technologies" => [ { "key" => "smr", "quote" => "small modular reactors" } ]
    }
    plugin = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found))
    claims = plugin.extract(Source.find_by!(url: HOME), nil)

    assert_equal [ [ "organization", "description" ], [ "organization", "hq_city" ], [ "organization", "founded_year" ],
      [ "organization_technology", "smr" ] ], # no categories: Data Quality's, by hand (28 Oct)
      claims.map { |c| [ c[:kind], c[:payload].except("name", "organization").first&.then { |k, v| c[:kind] == "organization" ? k : v } ] }
    assert(claims.all? { |c| c[:quote].present? })
  end

  test "a description must be inside its own quote, not just somewhere on the page" do
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    found = { "description" => { "value" => "Acme Fission Inc. designs small modular reactors.", "quote" => "Founded in 2019." },
      "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [] }
    assert_empty DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
  end

  test "the instructions carry Data Quality's rules" do
    rules = DataQuality::Plugins::CompanyPages::INSTRUCTIONS
    assert_includes rules, "a menu heading, a navigation label or a list\nof links is not enough"
    assert_includes rules, "If the page is about another company"
    assert_includes rules, "An office is not headquarters unless the page says so."
  end

  test "part 2: a listing with its ticker in the quote, and links naming the other party, in the directory's verbs" do
    page = <<~HTML
      <html><body><p>Acme Fission Inc. designs small modular reactors.</p><p>Acme Fission trades on NASDAQ under the symbol ACME.</p>
      <p>Acme Fission supplies fuel to Bright Power.</p><p>Acme Fission operates Latest Point.</p><p>Big Fund invested in Acme Fission.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => { "exchange" => "NASDAQ", "ticker" => "ACME", "quote" => "Acme Fission trades on NASDAQ under the symbol ACME." },
      "links" => [
        { "other" => "Bright Power", "other_is" => "company", "verb" => "supplies", "company_first" => true, "quote" => "Acme Fission supplies fuel to Bright Power." },
        { "other" => "Big Fund", "other_is" => "company", "verb" => "invests_in", "company_first" => false, "quote" => "Big Fund invested in Acme Fission." },
        { "other" => "Latest Point", "other_is" => "plant", "verb" => "operates", "company_first" => true, "quote" => "Acme Fission operates Latest Point." },
        { "other" => "Ghost Co", "other_is" => "company", "verb" => "funds", "company_first" => true, "quote" => "Acme Fission operates Latest Point." } # other not in quote
      ] }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)

    assert_includes claims, { kind: "organization", payload: { "name" => "Acme Fission", "exchange" => "NASDAQ", "ticker" => "ACME" },
      quote: "Acme Fission trades on NASDAQ under the symbol ACME." }
    assert_includes claims.map { |c| c[:payload] }, { "from_organization" => { "name" => "Acme Fission" }, "to_organization" => { "name" => "Bright Power" }, "relationship_type" => "supplies" }
    assert_includes claims.map { |c| c[:payload] }, { "from_organization" => { "name" => "Big Fund" }, "to_organization" => { "name" => "Acme Fission" }, "relationship_type" => "invests_in" }
    assert_includes claims.map { |c| c[:payload] }, { "organization" => { "name" => "Acme Fission" }, "facility" => { "name" => "Latest Point" }, "relationship_type" => "operates" }
    assert(claims.none? { |c| c[:payload].to_s.include?("Ghost Co") })
  end

  test "part 3: a company's EDGAR record gives its listing and business address (never its upper-case name as a legal name), each quoting the record" do
    edgar = "https://data.sec.gov/submissions/CIK0001849056.json?enrich=1"
    record = '{"cik":"0001849056","name":"OKLO INC.","tickers":["OKLO"],"exchanges":["NYSE"],"addresses":{"mailing":{"city":"X"},' \
      '"business":{"street1":"3190 Coronado Dr.","city":"SANTA CLARA","stateOrCountry":"CA","zipCode":"95054"}}}'
    stub_request(:get, "https://data.sec.gov/robots.txt").to_return(status: 404)
    stub_request(:get, edgar).to_return(body: record, headers: { "Content-Type" => "application/json" })
    @company.update_columns(enrich_requested_at: Time.current, sec_cik: "0001849056")

    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    claims = DataQuality::Plugins::CompanyPages.new.extract(Source.find_by!(url: edgar), nil)
    assert_equal [ { "name" => "Acme Fission", "exchange" => "NYSE", "ticker" => "OKLO" },
      { "name" => "Acme Fission", "hq_city" => "Santa Clara", "hq_state" => "CA" } ], claims.map { |c| c[:payload] }
    assert(claims.all? { |c| record.include?(c[:quote]) }, "every quote is a fragment of the record")
    assert_requested :get, edgar

    source = Source.find_by!(url: edgar)
    [ '"tickers":["BRK-A","BRK-B"],"exchanges":["NYSE","NYSE"],"addresses":{"business":{"street1":"PO Box 12","city":"OMAHA","stateOrCountry":"NE"}}}',
      '"tickers":["OKLO"],"exchanges":["NYSE","Nasdaq"],"addresses":{"business":{"street1":"1 Bay St","city":"TORONTO","stateOrCountry":"A6"}}}',
      '"tickers":["A","B"],"exchanges":["NYSE","NYSE"],"addresses":{"business":{"street1":"Post Office Box 12","city":"OMAHA","stateOrCountry":"NE"}}}' ].each do |rest|
      source.update_columns(content_text: '{"cik":"0001849056","name":"OKLO INC.",' + rest)
      assert_empty DataQuality::Plugins::CompanyPages.new.extract(source, nil), "several tickers, a PO box or a non-US code give nothing"
    end
  end

  test "a state by name is kept as its code; www and bare host are one site; a newer request made during a read stays waiting" do
    @company.update_columns(enrich_requested_at: 1.minute.ago)
    stub_request(:get, HOME).to_return(body: '<a href="https://acmefission.com/about">About</a><p>Headquartered in Austin, Texas.</p>', headers: { "Content-Type" => "text/html" })
    stub_request(:get, "https://acmefission.com/robots.txt").to_return(status: 404)
    stub_request(:get, "https://acmefission.com/about").to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
    directory = DataQuality::DirectoryClient.new
    queued = directory.enrich_queue
    @company.update_columns(enrich_requested_at: Time.current) # a newer request, mid-read
    DataQuality::Plugins::CompanyPages.new(directory: Struct.new(:queue, :real) do
      def enrich_queue(**) = queue
      def method_missing(name, ...) = real.public_send(name, ...)
      def respond_to_missing?(*) = true
    end.new(queued, directory)).crawl(nil)
    assert_requested :get, "https://acmefission.com/about"
    assert_equal [ @company.id ], directory.enrich_queue.map(&:first), "the newer request still waits"

    found = { "description" => nil, "hq_city" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "hq_state" => { "value" => "Texas", "quote" => "Headquartered in Austin, Texas." } }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_equal [ { "name" => "Acme Fission", "hq_state" => "TX" } ], claims.map { |c| c[:payload] }
  end

  test "a link needs a quote naming both parties, stating what is so now; an owner's quote says it owns" do
    page = <<~HTML
      <html><body><p>Bright Power supplies Dim Power.</p><p>Acme Fission plans to supply Bright Power.</p>
      <p>Acme Fission hosts the Latest Point site.</p><p>Acme Fission owns 40% of Latest Point.</p><p>We supply fuel to Bright Power.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    link = ->(other, other_is, verb, quote) { { "other" => other, "other_is" => other_is, "verb" => verb, "company_first" => true, "quote" => quote } }
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [
        link.("Bright Power", "company", "supplies", "Bright Power supplies Dim Power."),               # neither party is this company
        link.("Bright Power", "company", "supplies", "Acme Fission plans to supply Bright Power."),     # a plan
        link.("Latest Point", "plant", "owns", "Acme Fission hosts the Latest Point site."),          # hosting isn't owning
        link.("Latest Point", "plant", "owns", "Acme Fission owns 40% of Latest Point."),
        link.("Bright Power", "company", "supplies", "We supply fuel to Bright Power.") ] }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_equal [ "Acme Fission owns 40% of Latest Point.", "We supply fuel to Bright Power." ], claims.map { |c| c[:quote] }
  end

  test "a round the company says it raised is an announced deal term on the company, every value in its quote; a re-read lands on the same row" do
    page = <<~HTML
      <html><body><p>On December 6, 2024, Acme Fission closed a $37 million Series B.</p><p>We plan to raise a $500 million Series C.</p>
      <p>Bright Power raised $9 million.</p><p>We raised $12.5M in seed funding.</p>
      <p>We secured a $28M DOE award.</p><p>We closed a $5M financing contract.</p><p>We raised more than $90 million in our Series C.</p>
      <p>We announced on March 1, 2024 that we raised a $3 million seed round.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    round = ->(amount, name, date, quote) { { "amount" => amount, "round" => name, "date" => date, "quote" => quote } }
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [], "rounds" => [
        round.("$37 million", "Series B", "December 6, 2024", "On December 6, 2024, Acme Fission closed a $37 million Series B."),
        round.("$500 million", "Series C", nil, "We plan to raise a $500 million Series C."),  # a plan
        round.("$9 million", nil, nil, "Bright Power raised $9 million."),                     # another company's
        round.("$40 million", "Series B", nil, "On December 6, 2024, Acme Fission closed a $37 million Series B."), # not the quote's amount
        round.("$12.5M", "seed", nil, "We raised $12.5M in seed funding."),
        round.("$28M", nil, nil, "We secured a $28M DOE award."),                                    # an award
        round.("$5M", nil, nil, "We closed a $5M financing contract."),                               # a contract
        round.("$90 million", "Series C", nil, "We raised more than $90 million in our Series C."),   # inexact
        round.("$3 million", "seed", "March 1, 2024", "We announced on March 1, 2024 that we raised a $3 million seed round.") ] }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_equal [
      { "organization" => { "name" => "Acme Fission" }, "link_type" => "Organization", "term_type" => "funding_round", "status" => "announced",
        "external_id" => "page:#{HOME_KEY}#series b 37000000.0 2024-12-06", "amount_usd" => "37000000.0", "round" => "Series B", "starts_on" => "2024-12-06" },
      { "organization" => { "name" => "Acme Fission" }, "link_type" => "Organization", "term_type" => "funding_round", "status" => "announced",
        "external_id" => "page:#{HOME_KEY}#seed 12500000.0", "amount_usd" => "12500000.0", "round" => "seed" },
      { "organization" => { "name" => "Acme Fission" }, "link_type" => "Organization", "term_type" => "funding_round", "status" => "announced",
        "external_id" => "page:#{HOME_KEY}#seed 3000000.0", "amount_usd" => "3000000.0", "round" => "seed" } ], claims.map { |c| c[:payload] }
    assert(claims.all? { |c| c[:kind] == "deal_term" })
  end

  test "a listing needs its exchange in the quote; a provisional link is left to deal terms; an announcement's date isn't a closing date" do
    page = <<~HTML
      <html><body><p>Acme Fission trades under the symbol ACME.</p><p>Acme Fission signed an MOU with Bright Power to supply fuel.</p>
      <p>On March 1, 2024, we announced that we had closed a $3 million seed round.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => { "exchange" => "NASDAQ", "ticker" => "ACME", "quote" => "Acme Fission trades under the symbol ACME." },
      "links" => [ { "other" => "Bright Power", "other_is" => "company", "verb" => "supplies", "company_first" => true,
        "quote" => "Acme Fission signed an MOU with Bright Power to supply fuel." } ],
      "rounds" => [ { "amount" => "$3 million", "round" => "seed", "date" => "March 1, 2024",
        "quote" => "On March 1, 2024, we announced that we had closed a $3 million seed round." } ] }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_equal [ "deal_term" ], claims.map { |c| c[:kind] }, "no listing without NASDAQ in the quote, no plain link from an MOU"
    assert_nil claims.sole[:payload]["starts_on"], "March 1 is when it was announced"
  end

  test "an amount stands whole and in US dollars; a closing date after the verb counts; a reread with $37M is the same round" do
    page = <<~HTML
      <html><body><p>Acme Fission closed a $37 million Series B on December 6, 2024.</p><p>We raised $12 million CAD in a seed round.</p>
      <p>Acme Fission closed a $37M Series B on December 6, 2024.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    round = ->(amount, name, date, quote) { { "amount" => amount, "round" => name, "date" => date, "quote" => quote } }
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [], "deals" => [], "rounds" => [
        round.("$37", "Series B", nil, "Acme Fission closed a $37 million Series B on December 6, 2024."),                     # a prefix
        round.("$37 million", "Series B", "December 6, 2024", "Acme Fission closed a $37 million Series B on December 6, 2024."),
        round.("$12 million", "seed", nil, "We raised $12 million CAD in a seed round."),                                    # not US dollars
        round.("$37M", "Series B", "December 6, 2024", "Acme Fission closed a $37M Series B on December 6, 2024.") ] }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    payloads = claims.map { |c| c[:payload] }
    assert_equal [ "37000000.0", "37000000.0" ], payloads.map { |p| p["amount_usd"] }
    assert_equal "2024-12-06", payloads.first["starts_on"]
    assert_equal 1, payloads.map { |p| p["external_id"] }.uniq.size, "$37 million and $37M are one round"
  end

  test "an amount ending a sentence counts; tickers with digits or a hyphen are kept" do
    page = "<html><body><p>We closed a Series B funding round of $37 million.</p><p>Acme Fission is listed on NYSE as BRK-B.</p></body></html>"
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => { "exchange" => "NYSE", "ticker" => "BRK-B", "quote" => "Acme Fission is listed on NYSE as BRK-B." }, "links" => [],
      "rounds" => [ { "amount" => "$37 million", "round" => "Series B", "date" => nil, "quote" => "We closed a Series B funding round of $37 million." } ] }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_equal [ "BRK-B", "37000000.0" ], [ claims.find { |c| c[:payload]["ticker"] }&.dig(:payload, "ticker"), claims.find { |c| c[:kind] == "deal_term" }&.dig(:payload, "amount_usd") ]
  end

  test "two unnamed rounds of one amount on a page are two rounds" do
    page = <<~HTML
      <html><body><p>On December 6, 2024, Acme Fission closed a $5 million round of funding.</p>
      <p>On March 1, 2026, Acme Fission closed a $5 million round of funding.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    rounds = [ [ "December 6, 2024", "On December 6, 2024, Acme Fission closed a $5 million round of funding." ],
      [ "March 1, 2026", "On March 1, 2026, Acme Fission closed a $5 million round of funding." ] ]
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [], "rounds" => rounds.map { |date, quote| { "amount" => "$5 million", "round" => nil, "date" => date, "quote" => quote } } }
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_equal 2, claims.map { |c| c[:payload]["external_id"] }.uniq.size
  end

  test "an approximate amount isn't a round's amount; Enrich's SEC record has its own address, apart from Form D's" do
    page = "<html><body><p>We raised around $37 million in a Series B round.</p><p>We raised roughly $9 million in a seed round.</p></body></html>"
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [], "rounds" => [
        { "amount" => "$37 million", "round" => "Series B", "date" => nil, "quote" => "We raised around $37 million in a Series B round." },
        { "amount" => "$9 million", "round" => "seed", "date" => nil, "quote" => "We raised roughly $9 million in a seed round." } ] }
    assert_empty DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    assert_not_equal format(DataQuality::Plugins::SecFormD::SUBMISSIONS_URL, "0001849056"), format(DataQuality::Plugins::CompanyPages::EDGAR, 1_849_056)
  end

  test "an unnamed, undated round read again with its amount reworded is the same round" do
    plugin = DataQuality::Plugins::CompanyPages.new
    ids = [ [ "$5 million", "We closed a funding round of $5 million." ], [ "$5M", "We closed a funding round of $5M." ] ].map do |amount, quote|
      plugin.send(:funding_round, "Acme Fission", { "amount" => amount, "round" => nil, "date" => nil, "quote" => quote }, ->(_v, _q) { true }, HOME)[:payload]["external_id"]
    end
    assert_equal 1, ids.uniq.size, ids.inspect
  end

  test "a deal runs buyer to seller for power and supplier to buyer for supply; loose agreement words aren't deals" do
    page = <<~HTML
      <html><body><p>Acme Fission signed a power purchase agreement with Big Data Co for 500 MW on March 3, 2026.</p>
      <p>We signed a memorandum of understanding with Grid Co to buy its power.</p>
      <p>We signed a memorandum of understanding with Fuel Co for fuel supply.</p>
      <p>We signed a PPA with Later Co for 300 MW, and plan to sign another.</p>
      <p>Bright Power signed a PPA with Dim Power for 100 MW.</p><p>We work within the regulatory framework with Rule Co.</p>
      <p>We signed a supply agreement with Steel Co for up to $80 million.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    deal = ->(other, role, goods, capacity, date, quote) { { "other" => other, "role" => role, "goods" => goods, "amount" => nil, "capacity" => capacity, "date" => date, "quote" => quote } }
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [], "rounds" => [], "deals" => [
        deal.("Big Data Co", "seller", "power", "500 MW", "March 3, 2026", "Acme Fission signed a power purchase agreement with Big Data Co for 500 MW on March 3, 2026."),
        deal.("Grid Co", "buyer", "power", nil, nil, "We signed a memorandum of understanding with Grid Co to buy its power."),
        deal.("Fuel Co", "buyer", "supply", nil, nil, "We signed a memorandum of understanding with Fuel Co for fuel supply."),
        deal.("Later Co", "seller", "power", "300 MW", nil, "We signed a PPA with Later Co for 300 MW, and plan to sign another."), # a plan in the quote
        deal.("Dim Power", "seller", "power", "100 MW", nil, "Bright Power signed a PPA with Dim Power for 100 MW."),               # two other companies
        deal.("Rule Co", "seller", "power", nil, nil, "We work within the regulatory framework with Rule Co."),                     # not an agreement
        deal.("Steel Co", "seller", "supply", nil, nil, "We signed a supply agreement with Steel Co for up to $80 million.") ] }    # inexact
    claims = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil)
    ends = ->(claim) { [ claim[:payload].dig("from_organization", "name"), claim[:payload]["relationship_type"], claim[:payload].dig("to_organization", "name"), claim[:payload]["agreement"] ] }
    assert_equal [
      [ "Big Data Co", "offtake_with", "Acme Fission", "ppa" ],   # Big Data Co buys Acme's power
      [ "Acme Fission", "offtake_with", "Grid Co", "mou" ],       # Acme buys Grid Co's power
      [ "Fuel Co", "supplies", "Acme Fission", "mou" ] ], claims.map(&ends)
    first = claims.first[:payload]
    assert_equal [ "announced", "500.0", "2026-03-03", "page:#{HOME_KEY}#big data co ppa 500.0 mw 2026-03-03" ], first.values_at("status", "capacity_mw", "signed_on", "external_id")
  end

  test "a capacity stands whole; an announcement's date isn't a signing date; two same-size deals with one company stay two" do
    page = <<~HTML
      <html><body><p>We signed a PPA with Big Data Co for 1,500 MW.</p>
      <p>On March 1, 2026, we announced that we had signed a PPA with Grid Co for 500 MW.</p>
      <p>We signed a PPA with Grid Co for 500 MW in 2024.</p></body></html>
    HTML
    stub_request(:get, HOME).to_return(body: page, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    deal = ->(other, capacity, date, quote) { { "other" => other, "role" => "seller", "goods" => "power", "amount" => nil, "capacity" => capacity, "date" => date, "quote" => quote } }
    found = { "description" => nil, "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [],
      "listing" => nil, "links" => [], "rounds" => [], "deals" => [
        deal.("Big Data Co", "500 MW", nil, "We signed a PPA with Big Data Co for 1,500 MW."),
        deal.("Grid Co", "500 MW", "March 1, 2026", "On March 1, 2026, we announced that we had signed a PPA with Grid Co for 500 MW."),
        deal.("Grid Co", "500 MW", nil, "We signed a PPA with Grid Co for 500 MW in 2024.") ] }
    payloads = DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(Source.find_by!(url: HOME), nil).map { |c| c[:payload] }
    assert_equal [ "Grid Co", "Grid Co" ], payloads.map { |p| p.dig("from_organization", "name") }, "500 MW from '1,500 MW' is dropped"
    assert_nil payloads.first["signed_on"]
    assert_equal 2, payloads.map { |p| p["external_id"] }.uniq.size
  end

  test "gap fill: a published company with empty basics is read without being asked; one without a website is listed" do
    role = Role.create!(key: "gap_fill_test", name: "Gap fill test")
    OrganizationRole.create!(organization: @company, role:).verify!(by: "human:tosin")
    siteless = Organization.create!(name: "Siteless Fission", verification_status: "verified", verified_by: "human:tosin")
    OrganizationRole.create!(organization: siteless, role:).verify!(by: "human:tosin")
    stats = DataQuality::Stages::Crawl.call(plugin: DataQuality::Plugins::CompanyPages.new).stats

    assert_equal [ 1, 1 ], stats.values_at("gap_fill", "companies")
    assert_includes stats["gaps_without_website"], "Siteless Fission"
    assert @company.reload.enriched_at

    @company.update_columns(enrich_requested_at: nil, enriched_at: nil)
    assert_nil DataQuality::Stages::Crawl.call(plugin: DataQuality::Plugins::CompanyPages.new).stats["gap_fill"], "once a day, however the run starts"
  end

  test "companies that share one website each get their own findings; the domain's owner doesn't (#534)" do
    @company.update_columns(domain: nil)
    sister = Organization.create!(name: "Acme Sister Fission", website: HOME, verification_status: "verified", verified_by: "human:tosin")
    owner = Organization.create!(name: "Acme Holdings", website: "https://www.acmefission.com/", domain: "acmefission.com", verification_status: "verified", verified_by: "human:tosin")
    found = { "description" => { "value" => "Founded in 2019.", "quote" => "Founded in 2019." },
      "hq_city" => nil, "hq_state" => nil, "founded_year" => nil, "legal_name" => nil, "roles" => [], "technologies" => [] }

    sister.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    home = Source.find_by!(url: HOME)
    assert_equal sister.id, home.enrich_organization_id
    assert_equal [ "Acme Sister Fission" ], DataQuality::Plugins::CompanyPages.new(llm: FakeLLM.new(found)).extract(home, nil).map { |c| c[:payload]["name"] }.uniq
    refute_equal owner.id, home.enrich_organization_id
  end

  test "two queued companies on one website: the second waits a night, then its page is extracted again in its name (#534)" do
    @company.update_columns(domain: nil)
    sister = Organization.create!(name: "Acme Sister Fission", website: HOME, verification_status: "verified", verified_by: "human:tosin")
    @company.update_columns(enrich_requested_at: 2.minutes.ago)
    sister.update_columns(enrich_requested_at: 1.minute.ago)

    stats = DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    assert_equal 1, stats["deferred_shared_website"]
    home = Source.find_by!(url: HOME)
    assert_equal @company.id, home.enrich_organization_id
    assert_nil sister.reload.enriched_at, "still waiting"
    home.update_columns(extracted_sha256: "x", extracted_rows_sha256: "y")

    travel 1.day do
      DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
      home.reload
      assert_equal sister.id, home.enrich_organization_id
      assert_nil home.extracted_sha256, "extracted again, for the sister"
      assert sister.reload.enriched_at
    end
  end

  test "a home page that redirects: its relative links are read from where it ended (#525)" do
    stub_request(:get, HOME).to_return(status: 301, headers: { "Location" => "#{HOME}en/" })
    stub_request(:get, "#{HOME}en/").to_return(body: '<a href="about">About us</a>', headers: { "Content-Type" => "text/html" })
    en_about = stub_request(:get, "#{HOME}en/about").to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
    @company.update_columns(enrich_requested_at: Time.current)

    DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    assert_equal "#{HOME}en/", Source.find_by!(url: HOME).final_url
    assert_requested en_about
  end

  test "a CIK company with a malformed website: EDGAR is read, the website skipped, the request finished" do
    @company.update_columns(website: "https://bad host", sec_cik: "0001018724", enrich_requested_at: Time.current)
    stub_request(:get, "https://data.sec.gov/robots.txt").to_return(status: 404)
    stub_request(:get, %r{data\.sec\.gov/submissions/CIK0001018724\.json}).to_return(body: { name: "ACME", addresses: { business: {} } }.to_json)
    stats = DataQuality::Plugins::CompanyPages.new(gap_fill: 0).crawl(nil)
    assert_equal 1, stats["companies"]
    assert @company.reload.enriched_at
  end
end
