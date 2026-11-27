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

  test "a reject only when the strong model says it's out of scope, as a recommendation on its open claims" do
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

  test "the night's run keeps who it read, and the daily cap stops it before a model call" do
    counts = researcher(llm: FakeLlm.new(extract: answer)).call(@run)
    assert_equal 1, counts["researched"]
    assert_equal [ @org.id ], @run.reload.stats["researched"]

    other = Organization.create!(name: "Second Fission", website: "https://second.example", verification_status: "pending")
    CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify", started_at: NOW - 1.hour, stats: { "llm" => { "cost" => 1.0 } })
    llm = FakeLlm.new(extract: answer)
    assert_raises(DqPass::BudgetReached) { researcher(llm:, finder: FakeFinder.new(pages: { "https://second.example" => PAGE })).research(other) }
    assert_empty llm.asked
  end
end
