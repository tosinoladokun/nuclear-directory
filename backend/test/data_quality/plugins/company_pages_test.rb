require "test_helper"

# Enrich (#479): a requested company's own pages, read against the field
# list; only values in their quotes, quotes on the page, keys from the lists.
class DataQuality::Plugins::CompanyPagesTest < ActiveSupport::TestCase
  HOME = "https://www.acmefission.com/".freeze
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
    stats = DataQuality::Plugins::CompanyPages.new.crawl(nil)
    assert_equal({ "companies" => 0, "pages" => 0 }, stats)

    @company.update_columns(enrich_requested_at: Time.current)
    stats = DataQuality::Plugins::CompanyPages.new.crawl(nil)
    assert_equal({ "companies" => 1, "pages" => 2 }, stats)
    assert_equal %w[company_pages company_pages], Source.where(url: [ HOME, ABOUT ]).pluck(:source_kind)
    assert_not_requested :get, "https://other.com/about"
    assert @company.reload.enriched_at
    assert_equal({ "companies" => 0, "pages" => 0 }, DataQuality::Plugins::CompanyPages.new.crawl(nil), "read once per request")
  end

  test "extract keeps only values in their quotes and quotes on the page; drops marketing, people and unknown keys" do
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new.crawl(nil)
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
      [ "organization_role", "reactor_vendor" ], [ "organization_technology", "smr" ] ],
      claims.map { |c| [ c[:kind], c[:payload].except("name", "organization").first&.then { |k, v| c[:kind] == "organization" ? k : v } ] }
    assert(claims.all? { |c| c[:quote].present? })
  end

  test "a description must be inside its own quote, not just somewhere on the page" do
    @company.update_columns(enrich_requested_at: Time.current)
    DataQuality::Plugins::CompanyPages.new.crawl(nil)
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
    DataQuality::Plugins::CompanyPages.new.crawl(nil)
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

  test "part 3: a company's EDGAR record gives its legal name, listing and business address, each quoting the record" do
    edgar = "https://data.sec.gov/submissions/CIK0001849056.json"
    record = '{"cik":"0001849056","name":"OKLO INC.","tickers":["OKLO"],"exchanges":["NYSE"],"addresses":{"mailing":{"city":"X"},' \
      '"business":{"street1":"3190 Coronado Dr.","city":"SANTA CLARA","stateOrCountry":"CA","zipCode":"95054"}}}'
    stub_request(:get, "https://data.sec.gov/robots.txt").to_return(status: 404)
    stub_request(:get, edgar).to_return(body: record, headers: { "Content-Type" => "application/json" })
    @company.update_columns(enrich_requested_at: Time.current, sec_cik: "0001849056")

    DataQuality::Plugins::CompanyPages.new.crawl(nil)
    claims = DataQuality::Plugins::CompanyPages.new.extract(Source.find_by!(url: edgar), nil)
    assert_equal [ { "name" => "Acme Fission", "legal_name" => "OKLO INC." }, { "name" => "Acme Fission", "exchange" => "NYSE", "ticker" => "OKLO" },
      { "name" => "Acme Fission", "hq_city" => "Santa Clara", "hq_state" => "CA" } ], claims.map { |c| c[:payload] }
    assert(claims.all? { |c| record.include?(c[:quote]) }, "every quote is a fragment of the record")
    assert_requested :get, edgar
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
      def enrich_queue = queue
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
end
