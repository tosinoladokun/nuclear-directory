require "test_helper"

class DataQuality::Plugins::LeadFinderTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::LeadFinder
  HOME = "https://www.freshfission.example".freeze
  PAGE = "<html><head><title>Fresh Fission | Microreactors</title></head><body><h1>Fresh Fission</h1><p>Fresh Fission designs microreactors for remote sites.</p>" \
    "<p>Fresh Fission Inc., 1 Main St, Austin, TX 78701</p></body></html>".freeze

  setup do
    stub_request(:get, "#{HOME}/robots.txt").to_return(status: 404)
    stub_request(:get, HOME).to_return(body: PAGE, headers: { "Content-Type" => "text/html" })
    @searched = []
    @pipeline_runs = 0
  end

  def lead(name, url: nil) = Lead.sighted!(name:, kind: "company", key: "admin:#{name}", label: "Suggested by Tosin", url:)
  def finder(results: []) = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil,
    search: ->(query) { @searched << query; results }, pipeline: ->(plugin) { @pipeline_runs += 1; DataQuality::Stages::Extract.call(plugin:) })

  test "a website given: checked on its home page and proposed as a new company" do
    result = Plugin.call(lead("Fresh Fission", url: "#{HOME}/about").id, finder: finder)
    assert_equal :proposed, result.outcome
    assert_equal "https://www.freshfission.example", result.website
    claim = Candidate.find(result.candidate_id)
    assert_equal({ "name" => "Fresh Fission", "website" => "https://www.freshfission.example" }, claim.payload)
    assert_equal "Fresh Fission designs microreactors for remote sites.", claim.quote
    assert_empty @searched, "a first-party site needs no search"
  end

  test "a name only: found by the search API, then checked" do
    result = Plugin.call(lead("Fresh Fission").id, finder: finder(results: [ "https://www.linkedin.com/company/fresh", "#{HOME}/team" ]))
    assert_equal :proposed, result.outcome
    assert_equal [ "\"Fresh Fission\" nuclear" ], @searched
    assert_equal 1, result.found["searched"], "LinkedIn is never a website; results themselves are never kept (Brave's terms)"
    refute_includes result.found.to_s, "linkedin"
  end

  test "a LinkedIn link gives the name only and is never fetched" do
    result = Plugin.call(lead("https://www.linkedin.com/company/fresh-fission/").id, finder: finder(results: [ HOME ]))
    assert_equal "Fresh Fission", result.name
    assert_equal :proposed, result.outcome
    assert_not_requested :get, %r{linkedin\.com}
  end

  test "a news link: the site its About paragraph links" do
    news = "https://www.prnewswire.com/news-releases/fresh-1.html"
    stub_request(:get, "https://www.prnewswire.com/robots.txt").to_return(status: 404)
    stub_request(:get, news).to_return(body: "<html><body><p>News.</p><p><b>About Fresh Fission</b></p>" \
      "<p>Fresh Fission builds reactors. <a href=\"#{HOME}/\">freshfission</a> <a href=\"https://twitter.com/fresh\">X</a></p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = Plugin.call(lead("Fresh Fission", url: news).id, finder: finder)
    assert_equal :proposed, result.outcome
    assert_equal [ "https://www.freshfission.example" ], result.found["given"]
  end

  test "a company we have, by name or by its website, is a duplicate" do
    org = Organization.create!(name: "Fresh Fission", verification_status: "verified", verified_by: "human:tosin")
    org.aliases.find_or_create_by!(alias: "Fresh Fission")
    result = Plugin.call(lead("Fresh Fission").id, finder: finder)
    assert_equal [ :duplicate, org.id ], [ result.outcome, result.organization_id ]

    other = Organization.create!(name: "Old Name Fission", website: HOME, domain: "freshfission.example", verification_status: "verified", verified_by: "human:tosin")
    result = Plugin.call(lead("New Fission", url: HOME).id, finder: finder)
    assert_equal [ :duplicate, other.id ], [ result.outcome, result.organization_id ]
  end

  test "a site that states no nuclear work, or isn't the company, isn't confirmed" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>Fresh Fission sells solar panels. Austin, TX 78701</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = Plugin.call(lead("Fresh Fission", url: HOME).id, finder: finder)
    assert_equal :unconfirmed, result.outcome
    assert_equal "not_nuclear", result.found["checked"].sole["verdict"]
    assert_equal "No site checked out as this US nuclear company (freshfission.example: no nuclear work)", result.reason, "each site's verdict in the reason"

    result = Plugin.call(lead("Other Atom", url: HOME).id, finder: finder)
    assert_equal "not_named", result.found["checked"].sole["verdict"]
    assert_equal 0, @pipeline_runs
  end

  test "nothing to go on: unconfirmed, with no search without a key" do
    result = Plugin.call(lead("Ghost Nuclear").id, finder: Plugin.new(search_key: nil))
    assert_equal [ :unconfirmed, "No website found" ], [ result.outcome, result.reason ]
  end

  test "at most #{Plugin::SEARCHES_PER_DAY} searches a day, each counted for the month's cost" do
    Plugin::SEARCHES_PER_DAY.times { |n| Plugin.call(lead("Ghost #{n} Nuclear").id, finder: finder) }
    over = Plugin.call(lead("One More Nuclear").id, finder: finder)
    assert_equal [ :retry, true ], [ over.outcome, over.reason.include?("search limit") ], "past the cap: tomorrow, not a try"
    assert_equal Plugin::SEARCHES_PER_DAY, @searched.size
    assert_equal Plugin::SEARCHES_PER_DAY, Plugin.searches_in(Date.current)
  end

  test "Suggest a company: the typed text is read in place of the lead's name (#752)" do
    typed = Lead.sighted!(name: "suggestion", kind: "company", key: "admin:1", label: "Suggested by Tosin")
    result = DataQuality::CompanySuggestion.call("#{HOME}/about", lead_id: typed.id, finder: finder)
    assert_equal [ :proposed, "Fresh Fission" ], [ result.outcome, result.name ], "a website alone: the name its own page gives"
    result = DataQuality::CompanySuggestion.call("Fresh Fission", lead_id: typed.id, finder: finder(results: [ HOME ]))
    assert_equal :proposed, result.outcome
    assert_equal %i[outcome candidate_id organization_id name website reason found], result.to_h.keys
  end

  test "at most #{Plugin::FINDS_PER_DAY} finds a day, then busy for tomorrow (Infra)" do
    Plugin::FINDS_PER_DAY.times { CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", stats: { "finds" => 1 }) }
    result = Plugin.call(lead("Fresh Fission", url: HOME).id, finder: finder)
    assert_equal :retry, result.outcome, "not one of the lead's tries"
    assert_match "limit", result.reason
    assert_not_requested :get, HOME
  end

  test "only a verified home page is ever extracted; the page itself stays a web page Enrich can take over (Copilot)" do
    stub_request(:get, HOME).to_return(body: "<html><head><title>Foreign Fission</title></head><body><p>Foreign Fission builds reactors in Canada.</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    Plugin.call(lead("Foreign Fission", url: HOME).id, finder: finder)
    page = Source.find_by!(url: HOME)
    assert_equal "web_page", page.source_kind
    assert_empty Plugin.new.extract(page, nil), "a page that failed verify is never extracted"
  end

  test "a name in capitals on the page still gives its quote (Copilot)" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>FRESH FISSION designs microreactors. Austin, TX 78701</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = Plugin.call(lead("Fresh Fission", url: HOME).id, finder: finder)
    assert_equal :proposed, result.outcome
    assert_equal "FRESH FISSION designs microreactors.", Candidate.find(result.candidate_id).quote
  end

  test "a news link alone: the name from its About heading (Copilot)" do
    news = "https://www.prnewswire.com/news-releases/fresh-2.html"
    stub_request(:get, "https://www.prnewswire.com/robots.txt").to_return(status: 404)
    stub_request(:get, news).to_return(body: "<html><body><p><b>About Fresh Fission</b></p><p>Fresh Fission builds reactors. <a href=\"#{HOME}\">site</a></p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = DataQuality::CompanySuggestion.call(news, lead_id: lead("typed").id, finder: finder)
    assert_equal [ :proposed, "Fresh Fission" ], [ result.outcome, result.name ]
  end

  test "DataQuality::LeadFinder.call(lead), as Backend's LeadFindJob calls it (#755)" do
    result = DataQuality::LeadFinder.call(lead("Fresh Fission", url: HOME), finder: finder)
    assert_equal :proposed, result.to_h[:outcome]
  end

  test "a busy pipeline is waited for, then :retry, never a lost try (Infra)" do
    slept = []
    busy = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, sleeper: ->(seconds) { slept << seconds },
      pipeline: ->(_) { raise DataQuality::Pipeline::AlreadyRunning })
    result = Plugin.call(lead("Fresh Fission", url: HOME).id, finder: busy)
    assert_equal :retry, result.outcome
    assert_equal [ Plugin::BUSY_WAIT ] * (Plugin::BUSY_TRIES - 1), slept
  end

  test "searches are at least #{Plugin::SEARCH_GAP} s apart (Brave's 1 a second)" do
    Plugin.class_variable_set(:@@last_search, nil)
    slept = []
    spaced = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, search: ->(_) { [] }, sleeper: ->(seconds) { slept << seconds })
    2.times { |n| Plugin.call(lead("Ghost #{n} Nuclear").id, finder: spaced) }
    assert_equal 1, slept.size
    assert_operator slept.first, :<=, Plugin::SEARCH_GAP
  end

  test "a Brave 429 makes the lead busy, not 'no website found' (Infra)" do
    Plugin.class_variable_set(:@@last_search, nil)
    stub_request(:get, %r{api\.search\.brave\.com}).to_return(status: 429)
    real = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: "k", sleeper: ->(_) { })
    assert_equal :retry, Plugin.call(lead("Ghost Nuclear").id, finder: real).outcome
  end

  test "a foreign company a person added (US operations shown elsewhere) isn't refused as not US; a crawler's lead still is (PM, 11 Nov)" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>Fresh Fission mines uranium for nuclear fuel. Saskatoon, Canada</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    crawled = Plugin.call(Lead.sighted!(name: "Fresh Fission", kind: "company", key: "newsletter:1:fresh", label: "Newsletter", url: HOME).id, finder: finder)
    assert_equal "not_us", crawled.found["checked"].sole["verdict"]

    added = Lead.sighted!(name: "Fresh Fission", kind: "company", key: "admin:suggest:fresh fission", label: "Added in the admin", url: HOME)
    assert_equal :proposed, Plugin.call(added.id, finder: finder).outcome
  end

  test "a home page with no address: its contact page's US address counts; a legal ending isn't needed on the page (Infra, 18 Nov)" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>Fresh Fission designs microreactors for remote sites.</p><a href=\"/contact\">Contact</a></body></html>",
      headers: { "Content-Type" => "text/html" })
    stub_request(:get, "#{HOME}/contact").to_return(body: "<html><body><p>1 Main St, Austin, TX 78701</p></body></html>", headers: { "Content-Type" => "text/html" })
    crawled = Lead.sighted!(name: "Fresh Fission Inc.", kind: "company", key: "newsletter:2:fresh", label: "Newsletter", url: HOME)
    result = Plugin.call(crawled.id, finder: finder)
    assert_equal :proposed, result.outcome
    assert_requested :get, "#{HOME}/contact"
    assert_equal "Fresh Fission designs microreactors for remote sites.", Candidate.find(result.candidate_id).quote
  end

  test "the company is named as its own page writes it, never as typed (Backend, 18 Nov)" do
    result = Plugin.call(lead("fresh fission", url: HOME).id, finder: finder)
    assert_equal "Fresh Fission", Candidate.find(result.candidate_id).payload["name"]

    other = "https://www.ffamerica.example"
    stub_request(:get, "#{other}/robots.txt").to_return(status: 404)
    stub_request(:get, other).to_return(body: "<html><head><title>Fresh Fission America | Home</title></head><body><p>Fresh Fission America designs microreactors. Austin, TX 78701</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    result = Plugin.call(lead("Fresh Fission Inc.", url: other).id, finder: finder)
    assert_equal "Fresh Fission America", Candidate.find(result.candidate_id).payload["name"]
  end

  test "a short full name still matches whole; the home page link never takes a contact place (Copilot)" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>GSE provides nuclear engineering services.</p>" \
      "<a href=\"/\">The Nuclear Company</a><a href=\"/about\">About</a><a href=\"/contact\">Contact</a></body></html>", headers: { "Content-Type" => "text/html" })
    stub_request(:get, "#{HOME}/about").to_return(body: "<html><body><p>Our story.</p></body></html>", headers: { "Content-Type" => "text/html" })
    stub_request(:get, "#{HOME}/contact").to_return(body: "<html><body><p>1 Main St, Austin, TX 78701</p></body></html>", headers: { "Content-Type" => "text/html" })
    crawled = Lead.sighted!(name: "GSE", kind: "company", key: "newsletter:3:gse", label: "Newsletter", url: HOME)
    assert_equal :proposed, Plugin.call(crawled.id, finder: finder).outcome
  end

  test "what a person said about the lead goes into the search (Backend #806)" do
    with_hints = Data.define(:id, :name, :kind, :urls, :keys, :hints)
    directory = DataQuality::DirectoryClient.new
    directory.define_singleton_method(:lead) { |id| with_hints.new(id:, name: "Ghost Nuclear", kind: "company", urls: [], keys: [], hints: [ "Austin microreactor startup" ]) }
    finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), directory:, search_key: nil, search: ->(query) { @searched << query; [] })
    Plugin.call(1, finder:)
    assert_equal [ "\"Ghost Nuclear\" Austin microreactor startup nuclear" ], @searched
  end

  test "the page's name: never a heading's other words, a possessive, a full stop, or a cut-down full name (Copilot)" do
    plugin = Plugin.new
    name = ->(quote, lead, sites = []) { plugin.send(:page_name, quote, lead, sites) }
    assert_equal "Fresh Fission", name.("Fresh Fission Builds Nuclear Reactors", "fresh fission")
    assert_equal "Fresh Fission America", name.("Fresh Fission America's microreactors power remote sites.", "Fresh Fission", [ "Fresh Fission America" ])
    assert_equal "Fresh Fission America", name.("Reactors built by Fresh Fission America.", "Fresh Fission", [ "Fresh Fission America | Home" ])
    assert_equal "Power To Hydrogen", name.("Power To Hydrogen supplies equipment for nuclear facilities.", "power to hydrogen")
  end

  test "a pending company with no website gets one looked for, proposed as its website claim, at most once a week (DQ, 19 Nov)" do
    pending = Organization.create!(name: "Fresh Fission")
    pending.aliases.find_or_create_by!(alias: "Fresh Fission")
    site_finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, search: ->(query) { @searched << query; [ HOME ] },
      pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    assert_equal :proposed, site_finder.find_sites[pending.id].outcome
    claim = Candidate.where(kind: "organization", subject_id: pending.id).sole
    assert_equal [ "Organization", pending.id ], [ claim.subject_type, claim.subject_id ], "matched to the pending company by name"
    assert_equal "https://www.freshfission.example", claim.payload["website"]
    assert_empty site_finder.find_sites, "not again within a week"
  end

  test "a pending company's site needn't show a US address: the official source that created it does (DQ, 19 Nov)" do
    stub_request(:get, HOME).to_return(body: "<html><body><p>Fresh Fission designs microreactors. Saskatoon, Canada</p></body></html>", headers: { "Content-Type" => "text/html" })
    pending = Organization.create!(name: "Fresh Fission")
    site_finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, search: ->(_) { [ HOME ] },
      pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    assert_equal :proposed, site_finder.find_sites[pending.id].outcome
  end

  test "a pending company's site is claimed for that company, never another; a blocked search comes back next run (Copilot)" do
    stub_request(:get, HOME).to_return(body: "<html><head><title>Fresh Fission America</title></head><body><p>Fresh Fission America designs microreactors.</p></body></html>",
      headers: { "Content-Type" => "text/html" })
    other = Organization.create!(name: "Fresh Fission America")
    other.aliases.find_or_create_by!(alias: "Fresh Fission America")
    pending = Organization.create!(name: "Fresh Fission")
    pending.aliases.find_or_create_by!(alias: "Fresh Fission")
    site_finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, search: ->(_) { [ HOME ] },
      pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    assert_equal :proposed, site_finder.find_site(pending.id, "Fresh Fission").outcome
    claim = Candidate.where(kind: "organization").order(:id).last
    assert_equal [ "Fresh Fission", pending.id ], [ claim.payload["name"], claim.subject_id ]

    capped = Plugin.new(search_key: nil, search: ->(_) { [] })
    Plugin::SEARCHES_PER_DAY.times { CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", stats: { "brave_searches" => 1 }) }
    lonely = Organization.create!(name: "Ghost Atomics")
    assert_equal :retry, capped.find_site(lonely.id, "Ghost Atomics").outcome
    refute_includes CrawlRun.where("stats ? 'site_for'").pluck(Arel.sql("(stats->>'site_for')::bigint")), lonely.id, "no week's rest for a blocked try"
  end

  test "a pending company whose proposing claim DQ rejected is never searched for (DQ, 19 Nov)" do
    junk = Organization.create!(name: "Summary Report Co")
    Candidate.create!(source: Source.create!(url: "https://www.nrc.gov/junk", source_kind: "nrc_adams", crawl_status: "ok"), kind: "organization",
      payload: { "name" => "Summary Report Co" }, quote: "Summary Report Co", subject: junk, status: "matched", dq_recommendation: "reject", dq_reason: "a document title")
    site_finder = Plugin.new(search_key: nil, search: ->(query) { @searched << query; [] })
    refute site_finder.find_sites.key?(junk.id)
    assert_empty @searched.grep(/Summary Report/)
  end
end
