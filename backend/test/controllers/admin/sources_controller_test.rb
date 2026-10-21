require "test_helper"

# Sources (#86, #201 part 2b): one row per source, grouped (official records,
# hand research by publisher), each source's documents, a search across
# them; folded under the list, sources that need attention with their CDN
# reference, the last run per stage, and spend against the budget.
class Admin::SourcesControllerTest < ActionDispatch::IntegrationTest
  # Every test starts from the defaults ($5 budget, no dashboard link),
  # whatever the developer's or CI's environment says.
  ENV_VARS = %w[DATA_QUALITY_MONTHLY_BUDGET POSTHOG_DASHBOARD_URL].freeze
  setup { @saved_env = ENV.to_h.slice(*ENV_VARS); ENV_VARS.each { ENV.delete(_1) } }
  teardown { ENV_VARS.each { ENV.delete(_1) }; @saved_env.each { |name, value| ENV[name] = value } }

  # Sets (or clears, with nil) an environment variable for the block, then restores it.
  def with_env(name, value)
    saved = ENV[name]
    value.nil? ? ENV.delete(name) : ENV[name] = value
    yield
  ensure
    saved.nil? ? ENV.delete(name) : ENV[name] = saved
  end

  test "needs a signed-in admin; the old status address leads to Overview, where the pipeline's health is" do
    get admin_sources_path
    assert_redirected_to new_session_path

    get "/admin/status"
    assert_redirected_to admin_root_path
  end

  VERIFIED = { verification_status: "verified", verified_by: "human:tosin" }.freeze

  def page(url, **attributes) = Source.create!(url:, source_kind: "web_page", domain: URI(url).host.delete_prefix("www."), **attributes)
  def backs(source, name) = Organization.create!(name:, **VERIFIED).tap { |o| Evidence.create!(subject: o, source:, quote: name, found_by: "human") }
  # Each cell as read on a wide screen (the phone-only plain count left out).
  def cells(row) = row.css("td").map { |td| td.dup.tap { |cell| cell.css(".nd-sources__plain").each(&:remove) }.text.squish }

  test "Sources: official records by crawler, hand research by publisher, with documents, facts, last read and status" do
    nrc = sources(:nrc).tap { |source| source.update!(crawl_status: "ok", fetched_at: Time.zone.parse("2026-10-15 07:00")) }
    backs(nrc, "Reactor Co")
    facts = SourceCatalog.entry("nrc_reactor_list").facts
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago, finished_at: 1.hour.ago,
      stats: { "candidates" => 219, "confirmed" => 219 })
    cfs = page("https://cfs.energy/technology/arc")
    backs(cfs, "CFS")
    page("https://cfs.energy/")
    page("https://www.world-nuclear-news.org/article")
    page("https://www.ornl.gov/news", crawl_status: "blocked", status_reason: "HTTP 403")
    sign_in_as users(:admin)

    get admin_sources_path

    assert_select "h1", /Sources\s+#{Source.count}/
    assert_select ".nd-shell__nav a[aria-current=page]", /Sources\s+#{Source.count}/
    official = SourceCatalog.official.reject(&:soon).sum(&:documents)
    research = SourceCatalog.research.sum(&:documents)
    assert_equal [ "Official records #{official}", "Hand research #{research}" ], css_select(".nd-sources__group").map { |row| row.text.squish }
    reactors = css_select("tr").find { |row| row.text.include?("NRC reactor list") }
    assert_equal [ "1", facts.to_s, "15 Oct 07:00", "OK" ], cells(reactors).drop(1)
    assert_match "Last run", cells(reactors).first
    assert_select "a[href=?]", admin_live_path(within: "nrc_reactor_list"), facts.to_s
    assert_select "tr", /\AUSAspending\s+0\s+0\s+—\s+Not read yet\z/, "in the daily crawl, before its first read"
    assert_select "tr", /EIA-860M index.*0\s+0\s+—\s+Not read yet/m, "a daily crawler before its first read"
    company = css_select("tr").find { |row| row.text.include?("Company sites") }
    sites = SourceCatalog.entry("company-sites")
    assert_equal [ "Company sites", sites.documents.to_s, sites.facts.to_s, "—", "Not checked by the crawler" ], cells(company)
    assert_select "tr", /Government\s+1\s+0\s+—\s+Blocked/, "a group's status is its worst document's"
  end

  test "one source: every document, folded by domain, with status chips (0 included) and each document's facts" do
    arc = page("https://cfs.energy/technology/arc", title: nil)
    home = page("https://cfs.energy/")
    backs(arc, "CFS")
    page("https://helionenergy.com/news", crawl_status: "ok")
    sign_in_as users(:admin)

    get admin_source_path(key: "company-sites")

    assert_select ".nd-crumbs li a[href=?]", admin_sources_path, "Sources"
    assert_select "h1", /Company sites\s+#{SourceCatalog.entry("company-sites").documents}/
    assert_select ".nd-fchip", /Not checked by the crawler\s+#{SourceCatalog.documents("company-sites").count { |d| d.status == "pending" }}/
    assert_select ".nd-fchip", /Blocked\s+0/
    assert_select ".nd-sources__toggle", /cfs\.energy\s+2/
    assert_select "#document-#{arc.id} a[href=?][target=_blank][rel=noopener][title=?]", arc.url, arc.url, /\/technology\/arc/
    assert_select "#document-#{home.id} a", /\/ \(home page\)/
    assert_select "#document-#{arc.id} a[href=?]", admin_live_path(within: "doc-#{arc.id}"), "1"

    get admin_source_path(key: "company-sites", status: "ok")
    assert_select "tr[id^=document-]", 1

    get admin_source_path(key: "no-such-group")
    assert_response :not_found
  end

  test "a match only in the address shows the address, marked" do
    page("https://cfs.energy/technology/arc", title: "CFS technology")
    sign_in_as users(:admin)

    get admin_sources_search_path(q: "arc")

    assert_select "td p mark", "arc"
  end

  test "Facts count only what Live lists: a source backing only a company's role counts 0" do
    source = page("https://www.example.org/roles")
    company = Organization.create!(name: "Role Only Co", **VERIFIED)
    role = OrganizationRole.create!(organization: company, role: Role.first || Role.create!(key: "utility", name: "Utility"), **VERIFIED)
    Evidence.create!(subject: role, source:, quote: "a utility", found_by: "human")

    assert_equal 0, SourceCatalog.documents(SourceCatalog.entry("company-sites").key).find { |doc| doc.id == source.id }&.facts.to_i
  end

  test "the last run's Changed is that run's own; the Checks backlog shows as waiting" do
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago, finished_at: 1.hour.ago,
      stats: { "candidates" => 10, "confirmed" => 7 })
    Candidate.create!(source: sources(:nrc), kind: "organization", payload: { "name" => "X" }, quote: "q", status: "needs_review")
    sign_in_as users(:admin)

    get admin_sources_path

    assert_select "details.nd-sources__run p", /Read 10 · Same 7 · Changed 3\s+· 1 waiting/
  end

  test "a failed match run says so, with its reason" do
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "failed", started_at: 1.hour.ago, finished_at: 1.hour.ago,
      error: "Timeout reading the list")
    sign_in_as users(:admin)

    get admin_source_path(key: "nrc_reactor_list")

    assert_select "section[aria-label='Last runs'] p", /The last read failed at .* · Timeout reading the list/
    assert_select "section[aria-label='Last runs'] td", /Failed · Timeout reading the list/
  end

  test "a source's page: a crawl that failed after a good match, or before any, says so" do
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.days.ago, finished_at: 2.days.ago,
      stats: { "candidates" => 10, "confirmed" => 9 })
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "failed", started_at: 1.hour.ago, finished_at: 1.hour.ago, error: "HTTP 503")
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "failed", started_at: 1.hour.ago, finished_at: 1.hour.ago, error: "Timeout")
    sign_in_as users(:admin)

    get admin_source_path(key: "nrc_reactor_list")
    assert_select "section[aria-label='Last runs'] p", /The last read failed at .* · HTTP 503/
    assert_select "section[aria-label='Last runs'] p", "Earlier run"
    assert_select "section[aria-label='Last runs'] p", /Read 10 · Same 9 · Changed 1/

    get admin_source_path(key: "eia_generators")
    assert_select "section[aria-label='Last runs'] p", /The last read failed at .* · Timeout/
  end

  test "Sources: a match that failed after a good crawl says so, with its reason" do
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.days.ago, finished_at: 2.days.ago,
      stats: { "candidates" => 10, "confirmed" => 10 })
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.hours.ago, finished_at: 2.hours.ago)
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "failed", started_at: 1.hour.ago, finished_at: 1.hour.ago, error: "Bad file")
    sign_in_as users(:admin)

    get admin_sources_path

    assert_select "details.nd-sources__run p", /The last read failed: Bad file\. These are an earlier run's counts/
  end

  test "search matches title, address and domain, ignoring case, and marks the match" do
    page("https://cfs.energy/technology/arc")
    page("https://www.example.com/x", title: "CFS raises $863 million")
    page("https://www.energy.gov/ne/arc")
    sign_in_as users(:admin)

    get admin_sources_search_path(q: "CFS")

    assert_select "h1", /“CFS”\s+2 of #{Source.count}/
    assert_select "mark", "cfs"
    assert_select "mark", "CFS"
    assert_select "a[href=?]", admin_source_path(key: "company-sites"), /cfs\.energy/

    get admin_sources_search_path(q: "zzz")
    assert_select "p", /No sources match “zzz”/
  end

  test "Live from a source lists only what it backs, and its chip clears it" do
    cfs = page("https://cfs.energy/")
    backs(cfs, "From CFS Co")
    backs(page("https://helionenergy.com/"), "From Helion Co")
    sign_in_as users(:admin)

    get admin_live_path(within: "doc-#{cfs.id}")

    names = css_select(".nd-live__table tbody td:first-child a").map(&:text)
    assert_equal [ "From CFS Co" ], names
    assert_select "a.nd-fchip[href=?]", admin_live_path, /From: \/ \(home page\)/
  end

  test "a Facts count opens to that many records in Live: reactors, units without a docket and links too" do
    source = page("https://www.example.net/plant")
    site = Facility.create!(name: "Counted Site", **VERIFIED)
    reactor = Facility.create!(name: "Counted 1", parent: site, nrc_docket: "05099301", **VERIFIED)
    undocketed = Facility.create!(name: "Counted 2", parent: site, **VERIFIED)
    owner = Organization.create!(name: "Counted Owner", **VERIFIED)
    link = FacilityRelationship.create!(organization: owner, facility: site, relationship_type: "owns", **VERIFIED)
    [ reactor, undocketed, link ].each { |fact| Evidence.create!(subject: fact, source:, quote: "q", found_by: "human") }
    sign_in_as users(:admin)

    get admin_live_path(within: "doc-#{source.id}")

    assert_equal [ "Counted 1", "Counted 2", "Counted Owner owns Counted Site" ].sort, css_select(".nd-live__table tbody td:first-child a").map(&:text).sort
    assert_equal 3, SourceCatalog.documents("company-sites").find { |doc| doc.id == source.id }.facts
    assert_select ".nd-live__foot", /Showing 3 records/
    assert_select "a.nd-fchip--tab", /All\s+3/, "tab counts are the source's"
    assert_select "a.nd-fchip--tab", /Reactors\s+1/
    assert_select "a.nd-fchip--tab", /Links\s+1/
  end

  test "Last run says when the last read failed after an earlier match" do
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 2.days.ago, finished_at: 2.days.ago,
      stats: { "candidates" => 10, "confirmed" => 10 })
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "failed", started_at: 1.hour.ago, finished_at: 1.hour.ago,
      error: "Timeout")
    sign_in_as users(:admin)

    get admin_sources_path

    assert_select "details.nd-sources__run p", /The last read failed/
  end

  test "folded: blocked sources with the reason, the last run per stage and this month's spend" do
    blocked = Source.create!(url: "https://www.nrc.gov/list", source_kind: "nrc_reactor_list", crawl_status: "blocked",
      status_reason: "HTTP 403 from AkamaiGHost, reference #18.abc", blocked_streak: 2, fetched_at: Time.current)
    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago,
      finished_at: 1.hour.ago + 2, stats: { "list" => "blocked" })
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "failed", started_at: 30.minutes.ago,
      finished_at: 30.minutes.ago + 7, error: "RuntimeError: Error pulling: -1")
    sign_in_as users(:admin)

    with_env("POSTHOG_DASHBOARD_URL", nil) { get admin_root_path }

    assert_response :success
    assert_select "details summary", /Needs attention\s+1/
    assert_select "#source-#{blocked.id}", /Blocked:.*HTTP 403 from AkamaiGHost, reference #18\.abc.*Blocked 2 days in a row/m
    assert_select ".nd-fold__row", /nrc_reactor_list · Crawl/
    assert_select ".nd-fold__row", /Error pulling: -1/
    assert_select ".nd-fold__row", /of \$5\.00/
    assert_select "a", text: /PostHog/, count: 0
  end

  def spent!(cost)
    CrawlRun.create!(stage: "verify", source_kind: "nrc_reactor_list", status: "succeeded", started_at: Time.current,
      finished_at: Time.current, stats: { "llm" => { "calls" => 10, "total_tokens" => 1000, "cost" => cost } })
  end

  test "a failed run reads as an error; durations and stat names read as words" do
    CrawlRun.create!(stage: "crawl", source_kind: "eia_generators", status: "failed", started_at: 2.hours.ago,
      finished_at: 2.hours.ago + 4321, error: "RuntimeError: boom")
    CrawlRun.create!(stage: "extract", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago,
      finished_at: 1.hour.ago + 42.9, stats: { "ai_check" => { "agreed" => 95, "made_up" => 0 } })
    sign_in_as users(:admin)

    get admin_root_path

    assert_select ".nd-fold__row .text-critical", /Failed/
    assert_select ".nd-fold__row", /72 min/
    assert_select ".nd-fold__row", /42\.9 s/
    assert_select ".nd-fold__row", /AI check: agreed 95, made up 0/
  end

  test "spend: a plain line from 80%, a status message (not an alert) once it's used up" do
    sign_in_as users(:admin)
    spent!(4.2)
    get admin_root_path
    assert_select "p", /\$4\.20 of \$5\.00 used; model calls stop at 100%/
    assert_select ".nd-flash", 0

    spent!(1.0)
    get admin_root_path
    assert_select "p[role=status]", /budget is used up/
    assert_select "[role=alert]", 0
  end

  test "a budget of 0 refuses every call, so it reads as used up" do
    sign_in_as users(:admin)
    with_env("DATA_QUALITY_MONTHLY_BUDGET", "0") { get admin_root_path }
    assert_select "p[role=status]", /budget is used up/
  end

  test "links the PostHog dashboard when one is configured" do
    sign_in_as users(:admin)
    with_env("POSTHOG_DASHBOARD_URL", "https://us.posthog.com/project/1/dashboard/2") { get admin_root_path }

    assert_select "a[href=?]", "https://us.posthog.com/project/1/dashboard/2", text: /Visitors on PostHog/
  end

  test "Sources lists only the sources; the pipeline's health is on Overview" do
    sign_in_as users(:admin)
    get admin_sources_path
    assert_select "details summary", text: /Needs attention|Last run per stage|Model spend/, count: 0

    assert_select "[data-controller=moved-anchor][data-moved-anchor-to-value=?]", admin_root_path

    get admin_root_path
    assert_select "details summary", /Needs attention/
    assert_select ".nd-fold__row", /Nothing needs attention\.\s+\d+ (not fetched yet|OK)/ if css_select(".nd-fold__row").text.include?("Nothing needs")
    assert_select "details summary", /Last run per stage/
    assert_select "details summary", /Model spend/
  end
end
