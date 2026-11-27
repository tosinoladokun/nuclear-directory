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

  test "the company's own site passes on its address alone when its title and heading don't name it (#932)" do
    site = "https://www.sawtoothsim.example"
    stub_request(:get, "#{site}/robots.txt").to_return(status: 404)
    stub_request(:get, site).to_return(headers: { "Content-Type" => "text/html" }, body: "<html><head><title>Home</title></head><body>" \
      "<h1>Training that works</h1><p>Sawtooth Simulation builds nuclear plant simulators.</p><p>Idaho Falls, ID 83402</p></body></html>")
    company = Organization.create!(name: "Sawtooth Simulation", verification_status: "verified", verified_by: "human:tosin")

    assert_equal :proposed, site_finder(site).find_site(company.id, "Sawtooth Simulation").outcome
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
