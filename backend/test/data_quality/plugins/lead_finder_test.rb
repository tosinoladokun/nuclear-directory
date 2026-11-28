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
    stub_request(:get, HOME).to_return(body: "<html><head><title>GSE Solutions</title></head><body><p>GSE provides nuclear engineering services.</p>" \
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

  test "a Brave spend cap (402/403) or a used-up month (429, 0 left) stops searching for the day, across restarts; the lead is :retry (Infra)" do
    { 402 => {}, 403 => {}, 429 => { "X-RateLimit-Remaining" => "1, 0" } }.each do |status, headers|
      CrawlRun.where(source_kind: "lead_finder").delete_all
      WebMock.reset_executed_requests!
      Plugin.class_variable_set(:@@last_search, nil)
      stub = stub_request(:get, %r{api\.search\.brave\.com}).to_return(status:, headers:)
      first = Plugin.call(lead("Ghost #{status} A Nuclear").id, finder: Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: "k", sleeper: ->(_) { }))
      assert_equal :retry, first.outcome
      assert_match "search limit", first.reason, "what the health check counts (#821)"
      restarted = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: "k", sleeper: ->(_) { })
      assert_equal :retry, Plugin.call(lead("Ghost #{status} B Nuclear").id, finder: restarted).outcome
      assert_requested stub, times: 1 # stopped for the day, in a new process too
      remove_request_stub(stub)
    end

    travel 1.day do
      WebMock.reset_executed_requests!
      Plugin.class_variable_set(:@@last_search, nil)
      stub_request(:get, %r{api\.search\.brave\.com}).to_return(status: 200, body: { web: { results: [] } }.to_json)
      Plugin.call(lead("Ghost Tomorrow Nuclear").id, finder: Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: "k", sleeper: ->(_) { }))
      assert_requested :get, %r{api\.search\.brave\.com}, times: 1 # searches resume the next day
    end
  end

  test "a 429 with months left is a blip, not a stop; a 401 is a failure, not 'no website' (Copilot)" do
    Plugin.class_variable_set(:@@last_search, nil)
    stub = stub_request(:get, %r{api\.search\.brave\.com}).to_return(status: 429, headers: { "X-RateLimit-Remaining" => "0, 10" })
    finder = -> { Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: "k", sleeper: ->(_) { }) }
    assert_equal :retry, Plugin.call(lead("Ghost Blip A Nuclear").id, finder: finder.()).outcome
    Plugin.call(lead("Ghost Blip B Nuclear").id, finder: finder.())
    assert_requested stub, times: 2 # the month isn't used up: the next lead searches
    remove_request_stub(stub)

    stub_request(:get, %r{api\.search\.brave\.com}).to_return(status: 401)
    assert_equal :retry, Plugin.call(lead("Ghost Key Nuclear").id, finder: finder.()).outcome, "a fresh finder: a key problem is a failure, not 'no website'"
  end

  test "a lab's .edu subdomain is reduced to the university's home page (DQ, 20 Nov)" do
    plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil)
    sites = plugin.send(:candidates_for, "Caltech", [ "https://krl.caltech.edu/about", "https://www.mines.edu/x", "https://nuclear.mines.edu/" ], {})
    assert_equal [ "https://caltech.edu", "https://mines.edu" ], sites.uniq
  end

  test "a pending company's site needn't state nuclear work, only name it; each search's verdicts are kept for the misses breakdown (PM, 20 Nov)" do
    stub_request(:get, "https://mines.edu/").to_return(body: "<html><head><title>Colorado School of Mines</title></head><body><p>Colorado School of Mines, Golden. Admissions and research.</p></body></html>", headers: { "Content-Type" => "text/html" })
    stub_request(:get, "https://other.example/").to_return(body: "<html><body><p>Unrelated shop.</p></body></html>", headers: { "Content-Type" => "text/html" })
    stub_request(:get, %r{\Ahttps://(mines\.edu|other\.example)/robots\.txt}).to_return(status: 404)
    mines = Organization.create!(name: "Colorado School of Mines")
    ghost = Organization.create!(name: "Ghost Fission")
    site_finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil,
      search: ->(query) { query.include?("Mines") ? [ "https://nuclear.mines.edu/x" ] : [ "https://other.example/" ] },
      pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    found = site_finder.find_sites
    assert_equal :proposed, found[mines.id].outcome, found[mines.id].found.inspect
    assert_equal :unconfirmed, found[ghost.id].outcome
    miss = CrawlRun.where("stats->>'site_for' = ?", ghost.id.to_s).sole.stats
    assert_equal [ "unconfirmed", [ { "verdict" => "not_named" } ] ], miss.values_at("site_outcome", "checked")
  end

  test "only a university, a national lab or a power buyer may skip 'nuclear on the page'; a startup is still refused (Tosin, 20 Nov)" do
    page = ->(url, text) do
      stub_request(:get, "#{url}/").to_return(body: "<html><body><p>#{text}</p></body></html>", headers: { "Content-Type" => "text/html" })
      stub_request(:get, "#{url}/robots.txt").to_return(status: 404)
    end
    page.("https://ornl.gov", "Oak Ridge National Laboratory delivers science.")
    page.("https://bigcloud.example", "Big Cloud Inc runs data centers.")
    page.("https://quietstart.example", "Quiet Start Inc builds the future.")
    lab = Organization.create!(name: "Oak Ridge National Laboratory")
    buyer = Organization.create!(name: "Big Cloud Inc")
    startup = Organization.create!(name: "Quiet Start Inc")
    Candidate.create!(source: Source.create!(url: "https://news.example/ppa", source_kind: "wire_press"), kind: "relationship",
      payload: { "from_organization" => { "name" => "Big Cloud Inc" }, "to_organization" => { "name" => "Fission Co" }, "relationship_type" => "offtake_with" })
    sites = { "Oak Ridge" => "https://ornl.gov", "Big Cloud" => "https://bigcloud.example", "Quiet Start" => "https://quietstart.example" }
    site_finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil,
      search: ->(query) { Array(sites.find { |key, _| query.include?(key) }&.last) },
      pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    found = site_finder.find_sites
    assert_equal :proposed, found[lab.id].outcome, "a national lab's .gov root"
    assert_equal :proposed, found[buyer.id].outcome, "the buyer in a power deal"
    assert_equal :unconfirmed, found[startup.id].outcome, "a startup must state nuclear work"
    assert_equal [ { "verdict" => "not_nuclear" } ], CrawlRun.where("stats->>'site_for' = ?", startup.id.to_s).sole.stats["checked"]
  end

  test "a lead a person typed may show its nuclear work on another page of its site; a found one may not (DQ, 20 Nov: Fluor)" do
    home = "https://www.fluor.example"
    stub_request(:get, "#{home}/robots.txt").to_return(status: 404)
    stub_request(:get, "#{home}/").to_return(body: %(<html><body><p>Fluor builds plants for energy and chemicals.</p><a href="/">Nuclear engineering</a><a href="/nuclear-a">Nuclear A</a><a href="/nuclear-b">Nuclear B</a><a href="/markets/nuclear">Nuclear power</a><a href="/careers">Careers</a></body></html>),
      headers: { "Content-Type" => "text/html" })
    %w[nuclear-a nuclear-b].each { |path| stub_request(:get, "#{home}/#{path}").to_return(body: "<html><body><p>Nuclear news.</p></body></html>", headers: { "Content-Type" => "text/html" }) }
    stub_request(:get, "#{home}/markets/nuclear").to_return(body: "<html><body><p>Fluor has built nuclear reactors for decades.</p></body></html>", headers: { "Content-Type" => "text/html" })
    typed = Plugin.call(lead("fluor", url: home).id, finder: finder)
    assert_equal :proposed, typed.outcome, typed.reason
    assert_equal "Fluor has built nuclear reactors for decades.", Candidate.find(typed.candidate_id).quote
    assert_not_requested :get, "#{home}/careers"

    Candidate.delete_all
    Lead.delete_all # a found-only lead, not the person's one sighted again (Copilot)
    found = Plugin.call(Lead.sighted!(name: "Fluor", kind: "company", key: "trade_press:fluor", label: "Trade press", url: home).id, finder: finder)
    assert_equal :unconfirmed, found.outcome, "only person-added leads look past the home page"
  end

  test "the extra pages for person-added leads stop at NUCLEAR_PAGES_PER_DAY (Infra)" do
    Plugin::NUCLEAR_PAGES_PER_DAY.times { CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", stats: { Plugin::NUCLEAR_PAGES => 1 }) }
    home = "https://www.capped.example"
    stub_request(:get, "#{home}/robots.txt").to_return(status: 404)
    stub_request(:get, "#{home}/").to_return(body: %(<html><body><p>Capped builds plants.</p><a href="/nuclear">Nuclear</a></body></html>), headers: { "Content-Type" => "text/html" })
    assert_equal :unconfirmed, Plugin.call(lead("Capped", url: home).id, finder: finder).outcome
    assert_not_requested :get, "#{home}/nuclear"
  end

  def site_finder(*sites) = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, search: ->(_) { sites },
    pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })

  test "another company's page that names it in a testimonial is not its site (#932: Mainstream Engineering on calnanocorp.com)" do
    site = "https://www.calnanocorp.example"
    stub_request(:get, "#{site}/robots.txt").to_return(status: 404)
    stub_request(:get, site).to_return(headers: { "Content-Type" => "text/html" }, body: <<~HTML)
      <html><head><title>California Nanotechnologies | Cryomilling</title><meta property="og:site_name" content="California Nanotechnologies"></head>
      <body><header><img src="/logo.png" alt="California Nanotechnologies logo"></header><h1>Advanced materials processing</h1>
      <p>We cryomill powders for nuclear fuel and reactor research.</p>
      <blockquote><p>"Fast turnaround and careful work." Jane Doe, Mainstream Engineering. Mainstream Engineering builds nuclear instrumentation.</p></blockquote>
      <p>California Nanotechnologies, 17220 S Main St, Gardena, CA 90248</p></body></html>
    HTML
    company = Organization.create!(name: "Mainstream Engineering", verification_status: "verified", verified_by: "human:tosin")

    result = site_finder(site).find_site(company.id, "Mainstream Engineering")
    assert_equal :unconfirmed, result.outcome
    assert_equal [ "not_named" ], result.found["checked"].map { |check| check["verdict"] }
    assert_empty Candidate.where(kind: "organization")
  end

  test "a staging or preview host is never the website, even with the company's own text (#932: WSC on public-stag.3keysoft.com)" do
    staging = "https://public-stag.3keysoft.example"
    company = Organization.create!(name: "WSC, Inc.", verification_status: "verified", verified_by: "human:tosin")

    result = site_finder(staging).find_site(company.id, "WSC, Inc.")
    assert_equal :unconfirmed, result.outcome
    assert_equal [ "staging" ], result.found["checked"].map { |check| check["verdict"] }
    assert_not_requested :get, staging
    assert_empty Candidate.where(kind: "organization")
  end

  test "a staging wire link is never read as a release either (Copilot, #987)" do
    stub_request(:get, %r{\Ahttps://www\.hadron\.example/robots\.txt}).to_return(status: 404)
    html_page("https://www.hadron.example", "<html><head><title>Hadron Energy</title></head><body><p>Hadron Energy builds a micro modular reactor.</p></body></html>")
    staging = "https://staging.globenewswire.com/news-release/hadron.html"
    result = Plugin.call(listed_lead("Hadron Energy", "https://www.hadron.example", staging).id, finder: finder)
    assert_includes result.reason, "not US"
    assert_not_requested :get, staging
  end

  test "a staging link given as the lead is never read, not even for its name, and the note says why (Copilot, #932)" do
    staging = "https://public-stag.3keysoft.example"
    result = Plugin.call(lead(staging).id, finder: finder)
    assert_equal :unconfirmed, result.outcome
    assert_includes result.reason, "public-stag.3keysoft.example: staging host"
    assert_not_requested :get, staging
    assert_not_requested :get, "#{staging}/robots.txt"
  end

  test "only labels before the registered domain mark a staging host, multi-part suffixes included (Copilot, #932)" do
    plugin = Plugin.new(search_key: nil)
    staging = %w[https://public-stag.3keysoft.com https://staging.acme.co.uk https://dev2.acme.com https://www.uat.acme.com.au https://staging.acme.herokuapp.com]
    own = %w[https://stage.co.uk https://www.stage.co.uk https://www.devtech.com https://testing.com https://acme.com.au https://www.contest.co.uk]
    staging.each { |url| assert plugin.send(:staging_host?, url), url }
    own.each { |url| assert_not plugin.send(:staging_host?, url), url }
  end

  test "the company's own site passes on its address alone when its title and heading don't name it (#932)" do
    site = "https://www.sawtoothsim.example"
    stub_request(:get, "#{site}/robots.txt").to_return(status: 404)
    stub_request(:get, site).to_return(headers: { "Content-Type" => "text/html" }, body: "<html><head><title>Home</title></head><body>" \
      "<h1>Training that works</h1><p>Sawtooth Simulation builds nuclear plant simulators.</p><p>Idaho Falls, ID 83402</p></body></html>")
    company = Organization.create!(name: "Sawtooth Simulation", verification_status: "verified", verified_by: "human:tosin")

    assert_equal :proposed, site_finder(site).find_site(company.id, "Sawtooth Simulation").outcome
  end

  # A lead from a list (not a person's), so its own pages must show it's a US company (#987).
  def listed_lead(name, *urls) = urls.each_with_index.map { |url, i| Lead.sighted!(name:, kind: "company", key: "nea:805:#{i}", label: "NEA list", url:) }.last ||
    Lead.sighted!(name:, kind: "company", key: "nea:805", label: "NEA list")
  def html_page(url, body) = stub_request(:get, url).to_return(body:, headers: { "Content-Type" => "text/html" })

  test "a script-built home page with only its title and a link: the brand's main domain is checked and claimed (#987: Terrestrial; Copilot)" do
    stub_request(:get, %r{\Ahttps://(www\.)?terrestrial(usa|energy)\.example/robots\.txt}).to_return(status: 404)
    html_page("https://terrestrialusa.example", "<html><head><title>Terrestrial Energy: the most capital-efficient SMR</title>" \
      "<meta name=\"description\" content=\"Terrestrial Energy is building the most capital-efficient SMR nuclear plant.\"></head>" \
      "<body><div id=\"root\"></div><a href=\"https://www.terrestrialenergy.example/\"></a></body></html>")
    html_page("https://www.terrestrialenergy.example/", "<html><head><title>Terrestrial Energy</title></head><body>" \
      "<p>Terrestrial Energy is a developer of Generation IV nuclear plants that use its Integral Molten Salt Reactor.</p><a href=\"/contact\">Contact</a></body></html>")
    html_page("https://www.terrestrialenergy.example/contact", "<html><body><p>Reach Terrestrial Energy at our Charlotte, NC headquarters.</p></body></html>")

    result = Plugin.call(listed_lead("terrestrialusa.example", "https://terrestrialusa.example").id, finder: finder)
    assert_equal :proposed, result.outcome, result.reason
    claim = Candidate.find(result.candidate_id)
    assert_equal [ "Terrestrial Energy", "https://www.terrestrialenergy.example" ], claim.payload.values_at("name", "website"),
      "named by the title part its address carries, claimed on the main domain"
  end

  test "the company's own wire release can show it's US; a partner's release can't (#987: NuCube)" do
    stub_request(:get, %r{\Ahttps://(www\.)?(nucube\.example|globenewswire\.com)/robots\.txt}).to_return(status: 404)
    html_page("https://www.nucube.example", "<html><head><title>Home | NuCube Energy</title></head><body>" \
      "<p>NuCube Energy builds factory-made microreactors.</p></body></html>")
    own = "https://www.globenewswire.com/news-release/2026/06/25/1/0/en/nucube.html"
    partner = "https://www.globenewswire.com/news-release/2026/06/26/2/0/en/partner.html"
    html_page(own, "<html><body><p>NuCube Energy announced a listing.</p><h3>About NuCube Energy</h3>" \
      "<p>Founded in 2023 and headquartered in Idaho Falls, Idaho, NuCube is an advanced-nuclear technology company.</p></body></html>")
    # A partner's release, with both About sections: Acme's Austin address is never NuCube's (Copilot).
    html_page(partner, "<html><body><p>Acme Grid signed with NuCube Energy.</p><h3>About Acme Grid</h3><p>Acme Grid, 1 Main St, Austin, TX 78701.</p>" \
      "<h3>About NuCube Energy</h3><p>NuCube Energy develops factory-built microreactors.</p></body></html>")

    refused = Plugin.call(listed_lead("NuCube Energy", "https://www.nucube.example", partner).id, finder: finder)
    assert_includes refused.reason, "not US"
    Lead.delete_all
    Source.where(url: [ "https://www.nucube.example" ]).delete_all
    found = Plugin.call(listed_lead("NuCube Energy", "https://www.nucube.example", own).id, finder: finder)
    assert_equal :proposed, found.outcome, found.reason
  end

  test "a listing alone isn't US; with Delaware incorporation or a headquarters region it is (#987: Hadron)" do
    stub_request(:get, %r{\Ahttps://www\.hadron\.example/robots\.txt}).to_return(status: 404)
    html_page("https://www.hadron.example", "<html><head><title>Hadron Energy</title></head><body><p>Hadron Energy builds a micro modular reactor.</p>" \
      "<p>Hadron Energy, Inc. (Nasdaq: HDRN)</p><a href=\"/investor-relations\">Investor relations</a></body></html>")
    html_page("https://www.hadron.example/investor-relations", "<html><body><p>Stories and filings.</p></body></html>")
    assert_includes Plugin.call(listed_lead("Hadron Energy", "https://www.hadron.example").id, finder: finder).reason, "not US"

    plugin = Plugin.new(search_key: nil)
    # Its own story page, given with the lead (DQ), states its headquarters.
    story = "https://www.hadron.example/p/second-location"
    html_page(story, "<html><body><p>Our engineering headquarters will remain in the Bay Area.</p></body></html>")
    Lead.delete_all
    Source.where(url: "https://www.hadron.example").delete_all
    found = Plugin.call(listed_lead("Hadron Energy", "https://www.hadron.example", story).id, finder: finder)
    assert_equal :proposed, found.outcome, found.reason

    assert plugin.send(:us_text?, "Hadron Energy, Inc. (Nasdaq: HDRN). Hadron Energy, Inc. · Delaware")
    assert plugin.send(:us_text?, "Our engineering headquarters will remain in the Bay Area.")
    assert_not plugin.send(:us_text?, "Hadron Energy, Inc. (Nasdaq: HDRN)")
    assert_not plugin.send(:us_text?, "Nuclearis Energy, Inc. · Delaware"), "incorporation alone isn't headquarters"
    assert_not plugin.send(:us_text?, "Nuclearis Energy is incorporated in Wilmington, Delaware and headquartered in Buenos Aires, Argentina"),
      "an incorporation city isn't a US office (Copilot)"
    assert plugin.send(:us_text?, "Acme is incorporated in Delaware and headquartered in Austin, Texas")
  end

  test "'formed in' a year keeps the founding city; 'formed under the laws of' or in a state is incorporation (#994, DQ)" do
    plugin = Plugin.new(search_key: nil)
    assert plugin.send(:us_text?, "Acme Fission was formed in 2019 in Austin, Texas")
    assert_not plugin.send(:us_text?, "Nuclearis Energy was formed under the laws of Delaware, Wilmington, Delaware")
    assert_not plugin.send(:us_text?, "Nuclearis Energy was formed in Wilmington, Delaware and is based in Buenos Aires, Argentina")
  end

  test "a script-built home page whose brand's main domain is already listed is a duplicate, never a claim (#994, Infra)" do
    stub_request(:get, %r{\Ahttps://terrestrialusa\.example/robots\.txt}).to_return(status: 404)
    html_page("https://terrestrialusa.example", "<html><head><title>Terrestrial Energy: the most capital-efficient SMR</title></head>" \
      "<body><div id=\"root\"></div><a href=\"https://www.terrestrialenergy.example/\"></a></body></html>")
    listed = Organization.create!(name: "Terrestrial Energy Inc.", domain: "terrestrialenergy.example", verification_status: "verified",
      verified_by: "human:tosin")

    result = Plugin.call(listed_lead("terrestrialusa.example", "https://terrestrialusa.example").id, finder: finder)
    assert_equal :duplicate, result.outcome, result.reason
    assert_equal listed.id, result.organization_id
    assert_match "already listed", result.reason
    assert_not Candidate.exists?(kind: "organization"), "no claim"
    assert_not_requested :get, %r{terrestrialenergy\.example}
  end

  test "US forms: 'U.S.' before a space, City, ST and City, State; never a lone two-letter word" do
    [ "a U.S. company", "Indianapolis, IN 46204", "Charlotte, NC headquarters", "headquartered in Idaho Falls, Idaho", "Frederick, Maryland" ].each do |text|
      assert_match Plugin::US, text
    end
    [ "Toronto, ON", "CONTACT US", "London, England", "about us" ].each { |text| assert_no_match Plugin::US, text }
  end

  test "the short name the site uses for itself carries the quote (#987: FANCO)" do
    stub_request(:get, %r{\Ahttps://fanuclear\.example/(robots\.txt|about-us)}).to_return(status: 404)
    html_page("https://fanuclear.example", "<html><head><title>First American Nuclear Co.</title></head><body><header><a href=\"/\">" \
      "<img src=\"/uploads/FANCO-logo.svg\" alt=\"\"></a></header><p>First American Nuclear is developing a practical approach to utility-scale power.</p>" \
      "<p>FANCO is not merely developing a reactor.</p><p>310 E 96th St, Indianapolis, IN 46204</p></body></html>")

    result = Plugin.call(listed_lead("fanuclear.example", "https://fanuclear.example").id, finder: finder)
    assert_equal :proposed, result.outcome, result.reason
    claim = Candidate.find(result.candidate_id)
    assert_equal [ "First American Nuclear Co.", "FANCO is not merely developing a reactor." ], [ claim.payload["name"], claim.quote ]
  end

  test "a website alone is named by the title part its address carries, never 'Home' (#987)" do
    plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil)
    { "https://www.valaratomics.example" => [ "The New Atomic Age | Valar Atomics", "Valar Atomics" ],
      "https://www.nucube.example" => [ "Home | NuCube Energy", "NuCube Energy" ] }.each do |site, (title, name)|
      stub_request(:get, "#{site}/robots.txt").to_return(status: 404)
      html_page(site, "<html><head><title>#{title}</title></head><body></body></html>")
      assert_equal name, plugin.send(:site_name, [ site ])
    end
  end

  test "a generic first word never matches another company's address alone (DQ on #985)" do
    plugin = Plugin.new(search_key: nil)
    assert_not plugin.send(:host_names?, "https://www.advancedenergy.example", "Advanced Fission")
    assert_not plugin.send(:host_names?, "https://www.nuclearfuels.example", "Nuclear Engineering Partners")
    assert plugin.send(:host_names?, "https://www.sawtoothsim.example", "Sawtooth Simulation")
  end

  # Terrestrial's stored home page (#1015), trimmed: no links, its main domain only as canonical, its address only in
  # its own structured data, its words only in <noscript>.
  TERRESTRIAL_SHELL = <<~HTML.freeze
    <html><head><title>Terrestrial Energy: the most capital-efficient SMR</title>
    <meta name="description" content="Terrestrial Energy is building the most capital-efficient SMR nuclear plant for rapid deployment at scale. Generation IV technology built for lower costs and faster deployment where industry needs it most." />
    <link rel="canonical" href="https://www.terrestrialenergy.example/" />
    <script type="application/ld+json">{"@context": "https://schema.org", "@type": "Corporation", "name": "Terrestrial Energy",
      "address": {"@type": "PostalAddress", "streetAddress": "2730 W Tyvola Road, Suite 100", "addressLocality": "Charlotte",
      "addressRegion": "NC", "postalCode": "28217", "addressCountry": "US"}}</script></head>
    <body><div id="root"></div><noscript><p>Terrestrial Energy is building the most capital-efficient SMR nuclear plant for rapid deployment at scale.</p></noscript></body></html>
  HTML

  test "the company's own structured-data address shows it's US (#1015: Terrestrial's stored page)" do
    stub_request(:get, %r{\Ahttps://terrestrialusa\.example/robots\.txt}).to_return(status: 404)
    html_page("https://terrestrialusa.example", TERRESTRIAL_SHELL)
    result = Plugin.call(listed_lead("Terrestrial Energy", "https://terrestrialusa.example").id, finder: finder)
    assert_equal :proposed, result.outcome, result.reason
    assert_equal "Terrestrial Energy is building the most capital-efficient SMR nuclear plant for rapid deployment at scale.",
      Candidate.find(result.candidate_id).quote
  end

  test "structured data about another company never lends its address (DQ, #1015)" do
    plugin = Plugin.new(search_key: nil)
    parent = Source.new(url: "https://acme.example", content_text: TERRESTRIAL_SHELL.sub('"name": "Terrestrial Energy"', '"name": "Acme Holdings"'))
    assert_nil plugin.send(:structured_address, parent, "Terrestrial Energy")
    own = Source.new(url: "https://terrestrialusa.example", content_text: TERRESTRIAL_SHELL)
    assert_equal "Charlotte, NC 28217, United States", plugin.send(:structured_address, own, "Terrestrial Energy")
    assert_equal "Charlotte, NC 28217, United States", plugin.send(:structured_address, own, "Terrestrial Energy Inc."), "legal ending aside"
    # Only the whole name: a block named "Energy" or "Terrestrial Energy Holdings" isn't the company's (Copilot).
    [ "Energy", "Terrestrial Energy Holdings" ].each do |other|
      page = Source.new(url: "https://terrestrialusa.example", content_text: TERRESTRIAL_SHELL.sub('"name": "Terrestrial Energy"', "\"name\": \"#{other}\""))
      assert_nil plugin.send(:structured_address, page, "Terrestrial Energy"), other
    end
    # An address in another country is never US, even when it looks like City, ST (Copilot).
    perth = Source.new(url: "https://terrestrialusa.example", content_text: TERRESTRIAL_SHELL.sub('"addressLocality": "Charlotte"', '"addressLocality": "Perth"')
      .sub('"addressRegion": "NC"', '"addressRegion": "WA"').sub('"postalCode": "28217"', '"postalCode": "6000"').sub('"addressCountry": "US"', '"addressCountry": "AU"'))
    assert_nil plugin.send(:structured_address, perth, "Terrestrial Energy")
  end

  test "a page's canonical address of the same brand is followed like a link; another brand's never is (#1015)" do
    plugin = Plugin.new(search_key: nil)
    shell = Source.new(url: "https://terrestrialusa.example", content_text: TERRESTRIAL_SHELL)
    assert_equal "https://www.terrestrialenergy.example", plugin.send(:brand_domain, shell, "Terrestrial Energy")
    other = Source.new(url: "https://terrestrialusa.example", content_text: TERRESTRIAL_SHELL.sub("terrestrialenergy.example", "acmeholdings.example"))
    assert_nil plugin.send(:brand_domain, other, "Terrestrial Energy")
  end

  test "the nuclear sentence may be on the investor page, for any lead (#1015: Hadron, Deep Fission)" do
    stub_request(:get, %r{\Ahttps://www\.hadron\.example/robots\.txt}).to_return(status: 404)
    # Three nuclear-titled links first, then contact, about and investor: the investor page is still tried (Copilot).
    nuclear_links = %w[/reactor /fission /nuclear-safety].map { |path| "<a href=\"#{path}\">#{path}</a>" }.join
    html_page("https://www.hadron.example", "<html><head><title>Hadron Energy</title></head><body><p>Hadron Energy. Always on. Always ready.</p>" \
      "<p>Resilient power from a micro modular reactor.</p><p>3 Twin Dolphin Drive, Redwood City, CA 94065</p>#{nuclear_links}" \
      "<a href=\"/contact\">Contact</a><a href=\"/about\">About</a><a href=\"/investor-relations\">Investor relations</a></body></html>")
    %w[/reactor /fission /nuclear-safety /contact /about].each { |path| html_page("https://www.hadron.example#{path}", "<html><body><p>Hadron Energy news.</p></body></html>") }
    html_page("https://www.hadron.example/investor-relations", "<html><body><p>Hadron Energy is developing a 10 MW electric micro modular " \
      "reactor (MMR) designed for factory manufacturing.</p></body></html>")

    result = Plugin.call(listed_lead("Hadron Energy", "https://www.hadron.example").id, finder: finder)
    assert_equal :proposed, result.outcome, result.reason
    claim = Candidate.find(result.candidate_id)
    assert_equal [ "https://www.hadron.example", "Hadron Energy is developing a 10 MW electric micro modular reactor (MMR) designed for factory manufacturing." ],
      [ claim.payload["website"], claim.quote ]
  end

  test "a published company with no website is searched too, after the pending ones (PM, 24 Nov)" do
    pending = Organization.create!(name: "Fresh Fission")
    listed = Organization.create!(name: "Steady Fission", verification_status: "verified", verified_by: "human:tosin")
    Organization.create!(name: "Sited Fission", website: "https://sited.example", verification_status: "verified", verified_by: "human:tosin")
    ids = DataQuality::DirectoryClient.new.organizations_without_website(limit: 1_000).map(&:first)
    assert ids.index(pending.id) < ids.index(listed.id), "pending first"
    refute_includes ids, Organization.find_by!(name: "Sited Fission").id

    searched = []
    site_finder = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), search_key: nil, search: ->(query) { searched << query; [] })
    site_finder.find_sites
    assert(searched.any? { |query| query.include?("Steady Fission") })
  end

  test "200 resting or rejected pending companies never hide a published one with no website (Copilot)" do
    source = Source.create!(url: "https://www.nrc.gov/junk", source_kind: "nrc_adams", crawl_status: "ok")
    200.times do |i|
      org = Organization.create!(name: "Shelved Fission #{i}")
      if i.even?
        CrawlRun.create!(source_kind: "lead_finder", stage: "crawl", status: "succeeded", stats: { "site_for" => org.id })
      else
        Candidate.create!(source:, kind: "organization", payload: { "name" => org.name }, quote: org.name, subject: org,
          status: "matched", dq_recommendation: "reject", dq_reason: "a document title")
      end
    end
    listed = Organization.create!(name: "Steady Fission", verification_status: "verified", verified_by: "human:tosin")

    searched = []
    site_finder = Plugin.new(search_key: nil, search: ->(query) { searched << query; [] })
    open = Organization.where(verification_status: %w[pending verified], website: [ nil, "" ]).where.not("name LIKE 'Shelved Fission%'")
    found = site_finder.find_sites(limit: open.count)
    assert_includes found.keys, listed.id
    assert_empty found.keys & Organization.where("name LIKE 'Shelved Fission%'").ids
    assert_empty searched.grep(/Shelved Fission/)
  end
end
