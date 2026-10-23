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
