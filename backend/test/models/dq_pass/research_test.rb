require "test_helper"

# #998: the pass's research with a model, for pending companies code couldn't settle.
class DqPass::ResearchTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 12, 2, 10, 30)
  HOME = "https://www.acmefission.example".freeze
  PAGE = "<html><head><title>Acme Fission | Microreactors</title></head><body><nav>Menu Careers</nav>" \
    "<main><h1>Acme Fission</h1><p>Acme Fission designs and builds microreactors for remote sites.</p></main>" \
    "<footer>Copyright Acme</footer><script>var x = 1;</script></body></html>".freeze

  # Stands in for the lead finder: search results and pages, as Sources.
  class FakeFinder
    attr_reader :searched
    def initialize(results: [], pages: {}) = (@results, @pages, @searched = results, pages, [])

    def search_sites(name)
      @searched << name
      @results
    end

    # The lead finder's own test, on the page as stored.
    def own_site_for?(page, names) = DataQuality::Plugins::LeadFinder.new(search_key: nil).own_site_for?(page, names)
    def site_names(page) = DataQuality::Plugins::LeadFinder.new(search_key: nil).site_names(page)

    def read_page(url)
      html = @pages[url] or return
      Source.find_or_create_by!(url:) { |row| row.source_kind = "web_page" }.tap do |source|
        source.update!(content_text: html, title: Nokogiri::HTML(html).at_css("title")&.text, crawl_status: "ok")
      end
    end
  end

  # Stands in for OpenRouter: one answer per role, the calls kept.
  class FakeLlm
    attr_reader :asked
    def initialize(**answers) = (@answers, @asked = answers, [])

    def structured(role:, **args)
      @asked << [ role, args[:messages].last[:content] ]
      data = @answers.fetch(role)
      raise data if data.is_a?(Exception)

      DataQuality::OpenRouter::Client::Response.new(data:, model: "vendor/#{role}", usage: {})
    end
  end

  def answer(**over) = { "website" => HOME, "website_quote" => "Acme Fission | Microreactors", "role" => "reactor_vendor",
    "role_quote" => "Acme Fission designs and builds microreactors for remote sites.", "out_of_scope" => false, "sure" => true,
    "reason" => "Its own home page" }.merge(over.transform_keys(&:to_s))

  setup do
    %w[reactor_vendor components].each { |key| Role.find_by(key:) || Role.create!(key:, name: key.humanize) }
    @org = Organization.create!(name: "Acme Fission", verification_status: "pending")
    # The lead finder searched for it and couldn't confirm a site (code first).
    CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", stats: { DataQuality::Plugins::LeadFinder::SITE_FOR => @org.id })
    @run = CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify", started_at: NOW)
  end

  def researcher(llm:, finder: FakeFinder.new(results: [ HOME ], pages: { HOME => PAGE }), dry_run: false)
    DqPass::Research.new(llm:, finder:, dry_run:, now: NOW).tap { |made| made.run = @run }
  end

  def proposals = Candidate.where("notes LIKE ?", "Data Quality proposed it: Server pass%").order(:id)

  test "the cheap model's sure answer proposes the website and the role, each with its quote from the page read" do
    llm = FakeLlm.new(extract: answer)
    result = researcher(llm:).research(@org)

    assert_equal "proposed", result[:outcome]
    assert_equal [ :extract ], llm.asked.map(&:first), "no strong model when the cheap one is sure"
    website, role = proposals.to_a
    assert_equal [ "organization", { "name" => "Acme Fission", "website" => "https://www.acmefission.example" } ], [ website.kind, website.payload ]
    assert_equal "Acme Fission | Microreactors", website.quote
    assert_equal [ "organization_role", "reactor_vendor" ], [ role.kind, role.payload["role"] ]
    assert_match "Server pass (vendor/extract)", website.notes
  end

  test "only the page's main text goes to the model: no nav, footer or script" do
    llm = FakeLlm.new(extract: answer)
    researcher(llm:).research(@org)
    prompt = llm.asked.first.last
    assert_includes prompt, "designs and builds microreactors"
    assert_not_includes prompt, "Careers"
    assert_not_includes prompt, "Copyright"
    assert_not_includes prompt, "var x"
  end

  test "unsure goes to the strong model; still unsure, nothing is proposed" do
    llm = FakeLlm.new(extract: answer(sure: false), verify: answer(sure: false))
    assert_equal "unsure", researcher(llm:).research(@org)[:outcome]
    assert_equal %i[extract verify], llm.asked.map(&:first)
    assert_empty proposals

    llm = FakeLlm.new(extract: answer(sure: false), verify: answer)
    assert_equal "proposed", researcher(llm:).research(@org)[:outcome]
    assert_match "vendor/verify", proposals.first.notes
  end

  test "code checks every answer: a quote not on the page, a quote that doesn't name it, another company's site, an unknown role" do
    llm = FakeLlm.new(extract: answer(website_quote: "Acme Fission, the best reactors", role_quote: "We build the best reactors on Earth"))
    assert_equal "nothing", researcher(llm:).research(@org)[:outcome]

    llm = FakeLlm.new(extract: answer(website_quote: "designs and builds microreactors", role: "wizard"))
    assert_equal "nothing", researcher(llm:).research(@org)[:outcome]

    Organization.create!(name: "Other", website: "https://acmefission.example", verification_status: "verified", verified_by: "human:tosin")
    llm = FakeLlm.new(extract: answer(role: nil))
    assert_equal "nothing", researcher(llm:).research(@org)[:outcome]
    assert_empty proposals
  end

  CUSTOMER = "https://www.calnano.example".freeze
  CUSTOMER_PAGE = "<html><head><title>California Nanotechnologies | Cryomilling</title></head><body><main>" \
    "<h1>Advanced materials</h1><p>Acme Fission designs and builds microreactors for remote sites, and we mill their powders.</p></main></body></html>".freeze

  test "a customer's page that mentions the company is never its site, and no role or reject comes from it (DQ, #1005)" do
    finder = FakeFinder.new(results: [ CUSTOMER ], pages: { CUSTOMER => CUSTOMER_PAGE })
    llm = FakeLlm.new(extract: answer(website: CUSTOMER, website_quote: "Acme Fission designs and builds microreactors for remote sites"))
    assert_equal "no_own_page", researcher(llm:, finder:).research(@org)[:outcome]
    assert_empty llm.asked, "no model reads another party's page (DQ's trial)"

    llm = FakeLlm.new(extract: answer(sure: false), verify: answer(website: nil, out_of_scope: true))
    source = Source.create!(url: "https://records.example/award/9", source_kind: "arpa_e_projects")
    claim = Candidate.create!(source:, kind: "organization", status: "matched", quote: "Organization: Acme Fission", payload: { "name" => "Acme Fission" }, subject: @org)
    researcher(llm:, finder:).research(@org)
    assert_nil claim.reload.dq_recommendation, "not from another company's page"
    assert_empty proposals
  end

  test "its own site passes under an alias when the crawler's spelling fails the name test (DQ, #1005)" do
    org = Organization.create!(name: "ACME FISSION TECHNOLOGIES LLC", verification_status: "pending")
    OrganizationAlias.create!(organization: org, alias: "Acme Fission")
    CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", stats: { DataQuality::Plugins::LeadFinder::SITE_FOR => org.id })
    assert_equal "proposed", researcher(llm: FakeLlm.new(extract: answer)).research(org)[:outcome]
  end

  test "never a reject for a university, lab, government body, investor or a company a person suggested, even on the strong model's word (DQ, #1005)" do
    uni = Organization.create!(name: "Example University", website: HOME, verification_status: "pending")
    source = Source.create!(url: "https://records.example/award/10", source_kind: "arpa_e_projects")
    claim = Candidate.create!(source:, kind: "organization", status: "matched", quote: "Organization: Example University", payload: { "name" => "Example University" }, subject: uni)
    researcher(llm: FakeLlm.new(extract: answer(sure: false), verify: answer(role: nil, out_of_scope: true))).research(uni)
    assert_nil claim.reload.dq_recommendation
  end

  test "candidates: the website a claim proposes and its records' own pages come first, and Brave isn't asked (DQ's trial)" do
    source = Source.create!(url: "https://records.example/award/20", source_kind: "lead_finder")
    Candidate.create!(source:, kind: "organization", status: "matched", quote: "Acme Fission", subject: @org,
      payload: { "name" => "Acme Fission", "website" => HOME })
    finder = FakeFinder.new(results: [ "https://unrelated.example" ], pages: { HOME => PAGE })
    assert_equal "proposed", researcher(llm: FakeLlm.new(extract: answer), finder:).research(@org)[:outcome]
    assert_empty finder.searched
  end

  test "news, aggregator and .gov or .edu hosts are never a company's candidates, unless the company is that kind of body (DQ's trial)" do
    step = researcher(llm: FakeLlm.new(extract: answer))
    %w[https://www.prnewswire.com https://factrail.ai https://interconnection.fyi https://www.eia.gov https://chem.rutgers.edu].each do |url|
      assert_not step.allowed_host?(@org, url), url
    end
    assert step.allowed_host?(Organization.new(name: "Sandia National Laboratories"), "https://www.sandia.gov")
    assert step.allowed_host?(Organization.new(name: "California Institute of Technology"), "https://www.caltech.edu")
    assert step.allowed_host?(@org, HOME)
  end

  test "a short form the site gives itself in its title and address names the company (DQ's trial: SRP)" do
    org = Organization.create!(name: "Salt River Project", verification_status: "pending")
    CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", stats: { DataQuality::Plugins::LeadFinder::SITE_FOR => org.id })
    srp = "https://www.srpnet.example"
    page = "<html><head><title>SRP | Arizona electric power and water</title></head><body><main><p>SRP operates Palo Verde with partners as a public power utility.</p></main></body></html>"
    finder = FakeFinder.new(results: [ srp ], pages: { srp => page })
    llm = FakeLlm.new(extract: answer(website: srp, website_quote: "SRP | Arizona electric power and water", role: "utility",
      role_quote: "SRP operates Palo Verde with partners as a public power utility."))
    Role.find_by(key: "utility") || Role.create!(key: "utility", name: "Utility")
    assert_equal "proposed", researcher(llm:, finder:).research(org)[:outcome]
    assert_equal "https://www.srpnet.example", proposals.find { |claim| claim.payload["website"] }&.payload&.dig("website")
  end

  test "a stored website gets the same checks: a news host, or a page that isn't its own, reaches no model (Copilot)" do
    @org.update!(website: "https://www.prnewswire.com")
    llm = FakeLlm.new(extract: answer)
    assert_equal "no_own_page", researcher(llm:).research(@org)[:outcome]

    @org.update!(website: CUSTOMER)
    assert_equal "no_own_page", researcher(llm:, finder: FakeFinder.new(pages: { CUSTOMER => CUSTOMER_PAGE })).research(@org)[:outcome]
    assert_empty llm.asked
  end

  test "a website proposal still waiting to be matched, targeted at the company, is a candidate (Copilot)" do
    source = Source.create!(url: "https://records.example/proposal/1", source_kind: "web_page")
    waiting = Candidate.create!(source:, kind: "organization", status: "new", quote: "Acme Fission", payload: { "name" => "Acme Fission", "website" => HOME })
    DqAction.create!(candidate: waiting, action: "propose_fields", target_type: "Organization", target_id: @org.id, reason: "r", before: {}, created: [],
      by: DataQuality::Matching::BY)
    finder = FakeFinder.new(results: [ "https://unrelated.example" ], pages: { HOME => PAGE })
    assert_equal "proposed", researcher(llm: FakeLlm.new(extract: answer), finder:).research(@org)[:outcome]
    assert_empty finder.searched
  end

  test "when no page it holds is its own, Brave is asked (Copilot)" do
    source = Source.create!(url: CUSTOMER, source_kind: "lead_finder")
    Candidate.create!(source:, kind: "organization", status: "matched", quote: "Acme Fission", subject: @org, payload: { "name" => "Acme Fission" })
    finder = FakeFinder.new(results: [ HOME ], pages: { CUSTOMER => CUSTOMER_PAGE, HOME => PAGE })
    assert_equal "proposed", researcher(llm: FakeLlm.new(extract: answer), finder:).research(@org)[:outcome]
    assert_equal [ "Acme Fission" ], finder.searched
  end

  test "a page of several MB is parsed only up to PAGE_SCAN, and is still its own site with its text read (#1026)" do
    huge = PAGE.sub("</main>", "</main>#{'<div><p>filler text</p></div>' * 150_000}")
    assert_operator huge.bytesize, :>, DqPass::Research::PAGE_SCAN * 5
    llm = FakeLlm.new(extract: answer)
    assert_equal "proposed", researcher(llm:, finder: FakeFinder.new(results: [ HOME ], pages: { HOME => huge })).research(@org)[:outcome]
    assert_includes llm.asked.first.last, "designs and builds microreactors"
  end

  test "a 450 KB inline script before <main> doesn't push the page's own text and heading past the cap (Copilot, #1032)" do
    scripted = PAGE.sub("<body>", "<body><script>#{'var tracking = 1;' * 30_000}</script>")
    assert_operator scripted.bytesize, :>, DqPass::Research::PAGE_SCAN
    llm = FakeLlm.new(extract: answer)
    assert_equal "proposed", researcher(llm:, finder: FakeFinder.new(results: [ HOME ], pages: { HOME => scripted })).research(@org)[:outcome]
    assert_includes llm.asked.first.last, "designs and builds microreactors"
  end

  test "the instructions say a fusion developer is reactor_vendor and an EPC firm is reactor_services (DQ's trial)" do
    text = DqPass::Research::INSTRUCTIONS.squish
    assert_includes text, "A fusion developer"
    assert_includes text, "is reactor_vendor"
    assert_includes text, "Engineering, construction or EPC firms are reactor_services, even when they also do waste"
  end

  test "a reject only when the strong model says it's out of scope, from its own site, as a recommendation on its open claims" do
    @org.update!(website: HOME)
    source = Source.create!(url: "https://records.example/award/1", source_kind: "arpa_e_projects")
    claim = Candidate.create!(source:, kind: "organization", status: "matched", quote: "Organization: Acme Fission", payload: { "name" => "Acme Fission" }, subject: @org)
    researcher(llm: FakeLlm.new(extract: answer(website: nil, role: nil, out_of_scope: true))).research(@org)
    assert_nil claim.reload.dq_recommendation, "not on the cheap model's word"

    researcher(llm: FakeLlm.new(extract: answer(sure: false), verify: answer(website: nil, role: nil, out_of_scope: true))).research(@org)
    assert_equal "reject", claim.reload.dq_recommendation
  end

  test "a dry run proposes nothing and says what it would" do
    result = researcher(llm: FakeLlm.new(extract: answer), dry_run: true).research(@org)
    assert_equal "would_propose", result[:outcome]
    assert_equal %w[propose_fields propose_role], result[:proposed].map { |row| row["action"] }
    assert_empty proposals
  end

  test "which companies: code first, each once a week, not one already proposed or junk; a company with a website is read for its role" do
    fresh = Organization.create!(name: "Never Searched", verification_status: "pending")
    sited = Organization.create!(name: "Has Site Co", website: "https://hassite.example", verification_status: "pending")
    step = researcher(llm: FakeLlm.new(extract: answer))
    assert_equal [ @org, sited ], step.due
    assert_not_includes step.due, fresh

    @run.update!(stats: { "researched" => [ @org.id ] })
    assert_equal [ sited ], step.due, "tried this week"
    assert_includes DqPass::Research.new(now: NOW + 8.days).due, @org, "a week later"
  end

  test "the companies read stay on the run after the job finishes it, so the weekly retry still sees them (Copilot)" do
    Switch.set!(DqPass::KEY, true, by: "human:tosin")
    finder = FakeFinder.new(results: [ HOME ], pages: { HOME => PAGE })
    DqPassJob.steps = [ DqPass::Research.new(llm: FakeLlm.new(extract: answer), finder:, now: NOW) ]
    DqPassJob.perform_now(now: NOW)
    run = CrawlRun.where(source_kind: DqPass::SOURCE_KIND).order(:id).last
    assert_equal [ @org.id ], run.stats["researched"]
    assert_equal 1, run.stats["research_count"]
    assert_not_includes DqPass::Research.new(now: NOW + 1.hour).due, @org
  ensure
    DqPassJob.steps = nil
  end

  test "a company with a website whose home page redirected to www still gets its role (Copilot)" do
    @org.update!(website: "https://acmefission.example")
    finder = FakeFinder.new(pages: { "https://acmefission.example" => PAGE })
    finder.define_singleton_method(:read_page) do |url|
      super(url)&.tap { |source| source.update!(final_url: "https://www.acmefission.example/") }
    end
    llm = FakeLlm.new(extract: answer(website: nil))
    assert_equal "proposed", researcher(llm:, finder:).research(@org)[:outcome]
    assert_equal "reactor_vendor", proposals.last.payload["role"]
  end

  test "one company's failed model call is that company's, not the night's (Copilot)" do
    llm = FakeLlm.new(extract: DataQuality::OpenRouter::Client::RetriesExhausted.new("invalid output"))
    counts = researcher(llm:).call(@run)
    assert_equal 1, counts["research_error"]
    assert_equal [ @org.id ], @run.reload.stats["researched"]
  end

  test "the night's run keeps who it read, and the daily cap stops it before a model call" do
    counts = researcher(llm: FakeLlm.new(extract: answer)).call(@run)
    assert_equal 1, counts["research_count"]
    assert_equal [ @org.id ], @run.reload.stats["researched"]

    other = Organization.create!(name: "Second Fission", website: "https://second.example", verification_status: "pending")
    CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify", started_at: NOW - 1.hour, stats: { "llm" => { "cost" => 1.0 } })
    llm = FakeLlm.new(extract: answer)
    assert_raises(DqPass::BudgetReached) { researcher(llm:, finder: FakeFinder.new(pages: { "https://second.example" => PAGE })).research(other) }
    assert_empty llm.asked
  end
end
