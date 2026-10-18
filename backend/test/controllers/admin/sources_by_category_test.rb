require "test_helper"

# Sources by category (#166, Design's spec): which of the 9 categories have
# a live source, each category's sources with their status, and General.
class Admin::SourcesByCategoryTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:admin) }

  # Runs a crawler, so its sources are live.
  # A crawler's run, and the document it read (fetched with content, OK), so it's live.
  def run_crawler(kind, at: 1.hour.ago, read: true, crawl_status: "ok")
    source = Source.create!(url: "https://example.gov/#{kind}-#{SecureRandom.hex(3)}", source_kind: kind, crawl_status:,
      fetched_at: (at if read), content_sha256: (SecureRandom.hex(32) if read))
    CrawlRun.create!(stage: "crawl", source_kind: kind, status: "succeeded", started_at: at)
    source
  end

  def category(key) = css_select("details##{key}").first

  test "the switch: Source by source type and Source by category, each its own address" do
    get admin_sources_path
    assert_select "nav.nd-seg a[aria-current=page][href=?]", admin_sources_path, /Source by source type/
    assert_select "nav.nd-seg a[href=?]", admin_sources_path(by: "category"), /Source by category/

    get admin_sources_path(by: "category")
    assert_select "nav.nd-seg a[aria-current=page][href=?]", admin_sources_path(by: "category")
    assert_select "nav.nd-seg a", /By category/, "the short label for phones"
    assert_select "input[placeholder=?]", "Search all sources"
  end

  test "a category with no live source shows the flag, and the count line agrees" do
    run_crawler("nrc_reactor_list")

    get admin_sources_path(by: "category")

    flagged = css_select("details.nd-cov__cat summary .nd-flag").size
    assert_equal 8, flagged
    assert_select "p .nd-flag", "8 of 9 categories have no live source"
    assert_select "details#utilities[open] summary", /1 of 4.*Live/m
    assert_select "details#waste-decommissioning:not([open]) summary .nd-flag", "No live source"
  end

  test "a built source isn't live until its crawler has read something and run lately" do
    get admin_sources_path(by: "category")
    assert_select "details#government-research .nd-cov__src", /DOE awards \(USAspending\).*Built · #260, not running yet/m

    run_crawler("usaspending_doe_awards", at: 5.days.ago)
    get admin_sources_path(by: "category")
    assert_select "details#government-research summary .nd-flag", "No live source", "a run 5 days ago isn't live"

    run_crawler("usaspending_doe_awards")
    get admin_sources_path(by: "category")
    assert_select "details#government-research summary", /1 of 2.*Live/m
    assert_select "details#government-research .nd-cov__src a[href=?]", admin_source_path(key: "usaspending_doe_awards", back: admin_sources_path(by: "category")), "DOE awards (USAspending)"
  end

  test "an issue number links out to GitHub in a new tab; a source with none is Missing" do
    get admin_sources_path(by: "category")

    assert_select "details#waste-decommissioning a[href=?][target=_blank]", "https://github.com/tosinoladokun/nuclear-directory/issues/274", "#274"
    assert_select "details#government-research .text-critical", "Missing · no issue yet"
    assert_select "details#reactor-developers .nd-cov__src", /GAIN directory\s*leads only/
  end

  test "General lists the whole industry's sources; the lead researcher brings leads, not facts" do
    Source.create!(url: "https://www.world-nuclear-news.org/a", source_kind: "web_page", domain: "world-nuclear-news.org")

    get admin_sources_path(by: "category")

    assert_select "#general-heading", /General\s*whole industry/
    assert_select ".nd-cov__src", /World Nuclear News.*Hand research · 1 document\b/m
    assert_select ".nd-cov__src", /Daily lead researcher\s*leads for Data Quality, not facts.*Planned · #278/m
    assert_select "p", "Hand-research pages count in the category of the company or plant they back."
  end

  test "categories are matched by their stable slug, so renaming one keeps its sources" do
    config = YAML.load_file(SourceCoverage::FILE)
    config["categories"].find { |entry| entry["key"] == "reactor-developers" }["name"] = "Developers"
    renamed = SourceCoverage.new(config).categories.find { |category| category.key == "reactor-developers" }

    assert_equal "Developers", renamed.name
    assert_equal SourceCoverage.new.categories.find { |category| category.key == "reactor-developers" }.sources, renamed.sources
    assert_equal %w[utilities reactor-developers fuel components waste-decommissioning services power-buyers investors government-research],
      SourceCoverage.new.categories.map(&:key), "the buckets' slugs (#322), in DATA.md order"
  end

  test "live means a crawl read something lately: not re-processing old documents, nor a blocked fetch" do
    run_crawler("nrc_reactor_list", at: 5.days.ago)
    CrawlRun.create!(stage: "match", source_kind: "nrc_reactor_list", status: "succeeded", started_at: 1.hour.ago)
    get admin_sources_path(by: "category")
    assert_select "details#utilities .nd-cov__src", /NRC reactor list.*Built/m, "a recent match over old documents isn't a read"

    run_crawler("eia_generators", crawl_status: "blocked")
    get admin_sources_path(by: "category")
    assert_select "details#utilities .nd-cov__src", /EIA-860M generators.*Built/m, "a blocked fetch isn't a read"
    assert_select "details#utilities summary .nd-flag", "No live source"

    # Read OK days ago; today's fetch got a 503, which keeps the old content and records why.
    doe = run_crawler("usaspending_doe_awards", at: 4.days.ago)
    doe.update!(fetched_at: 1.hour.ago, status_reason: "HTTP 503")
    CrawlRun.create!(stage: "crawl", source_kind: "usaspending_doe_awards", status: "succeeded", started_at: 1.hour.ago)
    get admin_sources_path(by: "category")
    assert_select "details#government-research summary .nd-flag", "No live source", "a failed fetch over old content isn't a read"
  end

  test "a category's facts count each fact once, and its counts stay when a crawler goes stale" do
    unit = Facility.create!(name: "Shared Unit", verification_status: "verified", verified_by: "human:tosin")
    nrc = run_crawler("nrc_reactor_list")
    eia = run_crawler("eia_generators", at: 5.days.ago)
    [ nrc, eia ].each { |source| Evidence.create!(subject: unit, source:, quote: "Shared Unit", found_by: "crawler") }

    utilities = SourceCoverage.new.categories.find { |category| category.key == "utilities" }

    assert_equal 1, utilities.facts, "backed by NRC and EIA, counted once"
    assert_equal Source.where(source_kind: %w[nrc_reactor_list eia_generators]).count, utilities.documents, "EIA's stale document still counts"
    assert_equal 1, utilities.live_count
  end

  test "names with commas keep all of them; an empty hand-research group isn't linked" do
    get admin_sources_path(by: "category")

    assert_select ".nd-cov__src", /DOE program pages \(ARDP, GAIN vouchers, Fusion Milestone\)/
    assert_select ".nd-cov__src", /SEC Form D, 8-K and 10-K/
    assert_select ".nd-cov__src", /World Nuclear News/
    assert_select ".nd-cov__src a", { text: "World Nuclear News", count: 0 }, "no documents, no page to link to"
  end

  test "each count says what it counts to a screen reader" do
    get admin_sources_path(by: "category")

    assert_select "details#utilities summary .sr-only", %w[Live\ sources: Documents: Facts:].size
    assert_select "#general-heading ~ details summary .sr-only", 3
  end

  test "DOE awards aren't live while the USAspending API they come through is failing" do
    run_crawler("usaspending_doe_awards")
    # As the plug-in records it: fetched and OK, with no content of its own.
    api = run_crawler("usaspending_api")
    api.update!(content_sha256: nil)
    get admin_sources_path(by: "category")
    assert_select "details#government-research summary", /1 of 2.*Live/m

    api.update!(crawl_status: "blocked", status_reason: "HTTP 403")
    get admin_sources_path(by: "category")
    assert_select "details#government-research summary .nd-flag", "No live source", "yesterday's documents, today's API block"
  end

  test "hand research with no documents mapped to it says so without a count" do
    get admin_sources_path(by: "category")

    assert_select ".nd-cov__src", /Reddit \(r\/nuclear and others\).*Hand research(?! ·)/m
    assert_select ".nd-cov__src", { text: /Reddit.*0 documents/m, count: 0 }
  end

  test "a source opened from the category view, and a search from it, lead back to the category view" do
    back = admin_sources_path(by: "category")
    run_crawler("nrc_reactor_list")

    get back
    assert_select ".nd-cov__src a[href=?]", admin_source_path(key: "nrc_reactor_list", back:), "NRC reactor list"
    assert_select "form.nd-sources__search input[name=back][value=?]", back

    get admin_source_path(key: "nrc_reactor_list", back:)
    assert_select ".nd-crumbs a[href=?]", back, "Sources"
    assert_select "a.nd-fchip[href=?]", admin_source_path(key: "nrc_reactor_list", status: "ok", back:)

    get admin_sources_search_path(q: "nothing-matches-this", back:)
    assert_select ".nd-crumbs a[href=?]", back, "Sources"
    assert_select "a[href=?]", back, "Back to Sources"
    assert_select "form.nd-sources__search input[name=back][value=?]", back

    get admin_sources_search_path(q: "x", back: "https://elsewhere.example/")
    assert_select ".nd-crumbs a[href=?]", admin_sources_path, "Sources"
  end

  test "EIA isn't live when its newest workbook was blocked, though an older one read fine" do
    run_crawler("eia_860m_index")
    run_crawler("eia_generators", at: 1.day.ago)
    get admin_sources_path(by: "category")
    assert_select "details#utilities .nd-cov__src", /EIA-860M generators.*Live/m

    run_crawler("eia_generators", crawl_status: "blocked").update!(fetched_at: 1.hour.ago, status_reason: "HTTP 403", content_sha256: nil)
    get admin_sources_path(by: "category")
    assert_select "details#utilities .nd-cov__src", /EIA-860M generators.*Built/m
  end

  test "a hand-research task's issue isn't called a crawler; a crawler's is" do
    get admin_sources_path(by: "category")

    assert_select "details#power-buyers .nd-cov__src", /Hand research · #253/
    assert_select "details#power-buyers .nd-cov__src", { text: /crawler #253/, count: 0 }
    assert_select ".nd-cov__src", /Company newsrooms.*Hand research · \d+ documents? · crawler #128/m
  end

  test "the flag line reads right with one category uncovered, or one in all" do
    helpers = ApplicationController.helpers
    assert_equal "1 of 9 categories has no live source", helpers.uncovered_line(1, 9)
    assert_equal "8 of 9 categories have no live source", helpers.uncovered_line(8, 9)
    assert_equal "1 of 1 category has no live source", helpers.uncovered_line(1, 1)
  end

  test "a newer failed crawl isn't hidden by an earlier success" do
    run_crawler("nrc_reactor_list", at: 1.day.ago)
    get admin_sources_path(by: "category")
    assert_select "details#utilities .nd-cov__src", /NRC reactor list.*Live/m

    CrawlRun.create!(stage: "crawl", source_kind: "nrc_reactor_list", status: "failed", started_at: 1.hour.ago, error: "no workbook link")
    get admin_sources_path(by: "category")
    assert_select "details#utilities .nd-cov__src", /NRC reactor list.*Built/m
  end

  test "a source whose crawler exists is never listed as planned" do
    config = YAML.load_file(Rails.root.join("config/source_coverage.yml"))
    sources = config.fetch("categories").flat_map { |category| category.fetch("sources") } + config.fetch("general")
    crawled = sources.select { |source| source["kind"] && "DataQuality::Plugins::#{source['kind'].camelize}".safe_constantize }
    assert crawled.any?
    crawled.each { |source| assert_equal "built", source["status"], "#{source['name']} has a crawler, so it's built (or live once it runs)" }
  end
end
