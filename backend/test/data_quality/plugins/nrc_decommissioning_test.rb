require "test_helper"

# Fixtures are real NRC pages fetched 2026-10-16 with the plug-in's Fetcher,
# cut to their main content: the decommissioning list (21 rows) and the
# Crystal River 3 site page (an NRC staff name removed).
class DataQuality::Plugins::NrcDecommissioningTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcDecommissioning
  CR3_URL = "https://www.nrc.gov/facilities-safety/facility-finder/decommissioning/power-reactor/cr3"
  SITE_PAGES = %r{\Ahttps://www\.nrc\.gov/facilities-safety/facility-finder/(?:decommissioning/power-reactor|reactors)/[a-z0-9-]+\z}

  # Stands in for the extractor model: answers with what it's given, and
  # checks its answers against the real schema.
  class FakeLicensees
    attr_reader :texts
    attr_writer :answers

    def initialize(answers = [])
      @answers = answers
      @texts = []
    end

    def call(text, run:)
      @texts << text
      errors = JSONSchemer.schema(Plugin::Licensees::SCHEMA).validate({ "licensees" => @answers }).to_a
      raise "fake answered outside the schema: #{errors.first["error"]}" if errors.any?

      @answers
    end
  end

  # Publishes everything, so a hold can only come from a code check.
  class PublishEverything
    def call(_candidate) = DataQuality::Verdict.new(outcome: :publish, reason: "supported", confidence: 0.95)
  end

  ADP = "Accelerated Decommissioning Partners (ADP)"
  ADP_QUOTE = "ADP-CR3 became the NRC-licensed operator responsible for decommissioning and ADP-SF1 became the owner of the spent nuclear fuel."
  DUKE_QUOTE = "Per the agreement, Duke remains the NRC-licensed owner of the plant, property, and decommissioning trust fund but not the spent fuel."
  ADP_ROLE_QUOTE = "On October 1, 2020, Duke Energy Florida transferred the license for Crystal River Unit 3, to Accelerated Decommissioning Partners (ADP)."

  def answer(name, link, quote, decommissions: false, decommissioning_quote: "")
    { "name" => name, "link" => link, "quote" => quote, "decommissions" => decommissions, "decommissioning_quote" => decommissioning_quote }
  end

  setup do
    stub_request(:get, "https://www.nrc.gov/robots.txt").to_return(body: file_fixture("nrc/robots.txt").read)
    @list = stub_request(:get, Plugin::LIST_URL).to_return(body: list_html)
    @pages = stub_request(:get, SITE_PAGES).to_return(body: cr3_html)
  end

  def list_html = file_fixture("nrc/decommissioning/list.html").read
  def cr3_html = file_fixture("nrc/decommissioning/cr3.html").read
  def plugin(licensees = FakeLicensees.new) = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), licensees:)
  def crawl(with = plugin) = DataQuality::Stages::Crawl.call(plugin: with)
  def list_source = Source.find_by!(url: Plugin::LIST_URL)
  def stored(url, html) = Source.create!(url:, source_kind: "nrc_decommissioning", crawl_status: "ok", content_text: html,
    content_sha256: Digest::SHA256.hexdigest(html))

  test "is the plug-in for nrc_decommissioning" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_decommissioning")
  end

  test "reads the 21 rows of the list, each with its site page" do
    rows = Plugin::List.rows(list_html)

    assert_equal 21, rows.size
    cr3 = rows.find { |row| row.nrc_docket == "05000302" }
    assert_equal [ "Crystal River – Unit 3", "CR-3", "DPR-72", "07201035*(GL)", "Crystal River", "FL", CR3_URL ],
      [ cr3.name, cr3.acronym, cr3.license_number, cr3.isfsi, cr3.city, cr3.state, cr3.page_url ]
    assert_equal "Crystal River – Unit 3 | CR-3 | 05000302 | DPR-72 | 07201035*(GL) | Crystal River, FL", cr3.line
    assert_equal 20, rows.map(&:page_url).uniq.size, "San Onofre 2 and 3 share a page"
    assert rows.all? { |row| row.page_url&.start_with?("https://www.nrc.gov/") }
  end

  test "crawls the list, then each site page once" do
    run = crawl

    assert run.succeeded?
    assert_equal({ "list" => "changed", "units" => 21, "site_pages" => { "changed" => 20 }, "failed_pages" => [] }, run.stats)
    assert_requested @pages, times: 20
    cr3 = Source.find_by!(url: CR3_URL)
    assert_equal [ "nrc_decommissioning", true ], [ cr3.source_kind, cr3.crawl_ok? ]
    assert_equal "Locations of Power Reactor Sites Undergoing Decommissioning | Nuclear Regulatory Commission", list_source.title
  end

  test "fetches at most once a day" do
    crawl
    second = crawl

    assert_equal "skipped_recent", second.stats["list"]
    assert_equal({ "skipped_recent" => 20 }, second.stats["site_pages"])
    assert_requested @list, times: 1
    assert_requested @pages, times: 20
  end

  test "a blocked list stops the crawl before any site page" do
    stub_request(:get, Plugin::LIST_URL).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)

    assert_equal({ "list" => "blocked", "stopped" => "list page blocked" }, crawl.stats)
    assert list_source.crawl_blocked?
    assert_not_requested @pages
  end

  test "a blocked site page stops the crawl there" do
    stub_request(:get, SITE_PAGES).to_return(status: 403, body: "Access Denied")

    stats = crawl.stats

    assert_equal({ "blocked" => 1 }, stats["site_pages"])
    assert_equal "site page blocked", stats["stopped"]
    assert_requested @pages, times: 1
  end

  test "a same-day rerun after a blocked site page fetches no later page" do
    stub_request(:get, SITE_PAGES).to_return(status: 403, body: "Access Denied")
    crawl

    second = crawl

    assert_equal({ "skipped_recent" => 1 }, second.stats["site_pages"])
    assert_equal "site page blocked", second.stats["stopped"]
    assert_requested @pages, times: 1
  end

  test "a failed site page is reported by id, and still on a same-day rerun that skips it, until it reads cleanly (#429)" do
    stub_request(:get, CR3_URL).to_return(status: 500, body: "oops")
    first = crawl.stats
    cr3 = Source.find_by!(url: CR3_URL)
    assert_equal 1, first["site_pages"]["error"]
    assert_equal [ cr3.id ], first["failed_pages"]

    assert_equal [ cr3.id ], crawl.stats["failed_pages"], "skipped today, still failed"

    Source.update_all(fetched_at: 2.days.ago)
    stub_request(:get, CR3_URL).to_return(body: "<html><body><p>Crystal River</p></body></html>")
    assert_equal [], crawl.stats["failed_pages"]
  end

  test "a site page is read again when the list maps a new unit to it, though its text is the same" do
    licensees = FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ])
    with = plugin(licensees)
    cr3_links = -> { Candidate.where(kind: "facility_relationship").select { |c| c.source.url == CR3_URL }.map { |c| c.payload.dig("facility", "nrc_docket") }.sort }
    crawl(with)
    DataQuality::Stages::Extract.call(plugin: with)
    assert_equal [ "05000302" ], cr3_links.call

    # Next day the list puts Dresden 1 on Crystal River's page too; the page itself is unchanged.
    moved = list_html.sub("/facilities-safety/facility-finder/decommissioning/power-reactor/dresden-nuclear-power-station-unit-1",
      "/facilities-safety/facility-finder/decommissioning/power-reactor/cr3")
    stub_request(:get, Plugin::LIST_URL).to_return(body: moved)
    Source.update_all(fetched_at: 2.days.ago)
    calls = licensees.texts.size

    run = crawl(with)
    DataQuality::Stages::Extract.call(plugin: with)

    assert_equal 19, run.stats["site_pages"]["unchanged"], "no page changed (Dresden 1 no longer has its own)"
    assert_equal [ "05000010", "05000302" ], cr3_links.call
    assert_equal calls + 1, licensees.texts.size, "only Crystal River's page is read again"
    dresden_page = Source.find_by!(url: "https://www.nrc.gov/facilities-safety/facility-finder/decommissioning/power-reactor/dresden-nuclear-power-station-unit-1")
    assert dresden_page.candidates.any?
    assert dresden_page.candidates.all? { |c| c.status_needs_review? && c.notes.include?(Plugin::UNLISTED) },
      "the page Dresden 1 left speaks for nothing now: a person decides its claims"
    assert_equal dresden_page.candidates.count, run.stats["withdrawn"]
  end

  SONGS_2_3 = "https://www.nrc.gov/facilities-safety/facility-finder/decommissioning/power-reactor/san-onofre-units-2-3"
  DRESDEN_1 = "https://www.nrc.gov/facilities-safety/facility-finder/decommissioning/power-reactor/dresden-nuclear-power-station-unit-1"

  def run_stages(with, *stages) = stages.each { |stage| DataQuality::Pipeline.run("nrc_decommissioning", plugin: with, only: stage) }

  def relist(html)
    stub_request(:get, Plugin::LIST_URL).to_return(body: html)
    Source.update_all(fetched_at: 2.days.ago)
  end

  # Publishes a page's link to a unit, with both its ends, as a person would.
  def publish_link(page_url, docket)
    page = Source.find_by!(url: page_url)
    unit = Source.find_by!(url: Plugin::LIST_URL).candidates.find { |c| c.kind == "facility" && c.payload["nrc_docket"] == docket }
    link = page.candidates.find { |c| c.kind == "facility_relationship" && c.payload.dig("facility", "nrc_docket") == docket }
    [ unit, page.candidates.find_by!(kind: "organization"), link ].each do |claim|
      result = DataQuality::Review.approve([ claim.id ], by: "human:test").first
      assert_empty result.errors, "approving #{claim.kind}"
    end
    FacilityRelationship.find(link.reload.subject_id)
  end

  test "a unit moved off a page: its published link goes to a person, nothing is rejected" do
    with = plugin(FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ]))
    run_stages(with, "crawl", "extract", "match")
    published = publish_link(SONGS_2_3, "05000361")
    songs = Source.find_by!(url: SONGS_2_3)
    unit_3 = songs.candidates.find { |c| c.kind == "facility_relationship" && c.payload.dig("facility", "nrc_docket") == "05000362" }

    # San Onofre 2 moves to the Unit 1 page; Unit 3 stays on this one, whose text doesn't change.
    relist(list_html.sub("san-onofre-units-2-3\">", "san-onofre-unit-1\">"))
    2.times { run_stages(with, "crawl") }

    assert published.reload.verified?, "a person decides; the crawl never unpublishes"
    flagged = songs.candidates.where(review_origin: "dropped")
    assert_equal [ published.id ], flagged.map(&:subject_id), "one review item, once"
    assert_match Plugin::DEPARTED, flagged.first.notes
    assert unit_3.reload.status_matched?, "Unit 3's link still holds"
    assert_equal 0, Candidate.status_rejected.count
  end

  test "a unit moved off a shared page: its open link waits in review through the page's next read" do
    with = plugin(FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ]))
    run_stages(with, "crawl", "extract", "match")
    songs = Source.find_by!(url: SONGS_2_3)
    link_for = ->(docket) { songs.candidates.where(kind: "facility_relationship").order(:id).find { |c| c.payload.dig("facility", "nrc_docket") == docket } }
    unit_2 = link_for.("05000361")

    relist(list_html.sub("san-onofre-units-2-3\">", "san-onofre-unit-1\">"))
    run_stages(with, "crawl", "extract", "match")

    assert Candidate.exists?(unit_2.id), "the read doesn't replace a withdrawn claim"
    assert_equal [ "needs_review", Plugin::WITHDRAWN, true ], [ unit_2.reload.status, unit_2.review_origin, unit_2.proposed_subject ]
    assert_match Plugin::DEPARTED, unit_2.notes
    assert link_for.("05000362").status_matched?
  end

  test "a page the list stops linking: its claims wait for a person, and come back as they were when it's linked again" do
    licensees = FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ])
    with = plugin(licensees)
    run_stages(with, "crawl", "extract", "match")
    dresden_page = Source.find_by!(url: DRESDEN_1)
    link = dresden_page.candidates.find_by!(kind: "facility_relationship")
    record = FacilityRelationship.find(link.subject_id)
    assert link.proposed_subject, "match proposed the Duke–Dresden 1 link for this page's claim"

    relist(list_html.sub("/facilities-safety/facility-finder/decommissioning/power-reactor/dresden-nuclear-power-station-unit-1",
      "/facilities-safety/facility-finder/decommissioning/power-reactor/cr3"))
    run_stages(with, "crawl", "extract", "match")

    assert_equal [ "needs_review", Plugin::WITHDRAWN ], [ link.reload.status, link.review_origin ]
    assert_match Plugin::UNLISTED, link.notes
    assert record.reload.pending?, "nothing is retired; a person decides"
    assert_equal 0, Candidate.status_rejected.count

    # NRC links the page again, with the same text.
    relist(list_html)
    calls = licensees.texts.size
    run_stages(with, "crawl", "extract", "match")

    assert_operator licensees.texts.size, :>, calls, "the page is read again"
    assert_equal [ "matched", nil, true, record.id ], [ link.reload.status, link.review_origin, link.proposed_subject, link.subject_id ],
      "back as match left it, still the claim that proposed the link"
    assert_match Plugin::LISTED_AGAIN, link.notes
    assert_equal 1, dresden_page.candidates.where(kind: "facility_relationship", status: %w[new matched needs_review]).count,
      "the read's repeat doesn't wait twice"

    # While Dresden 1 was on Crystal River's page, that page claimed the link too; that claim now waits, withdrawn.
    other = Candidate.where(subject_type: "FacilityRelationship", subject_id: record.id, status: "needs_review").sole
    assert_equal [ CR3_URL, Plugin::WITHDRAWN ], [ other.source.url, other.review_origin ]
    assert_empty DataQuality::Review.reject([ link.id ], by: "human:test", reason: "not the licensee").first.errors
    assert record.reload.pending?, "a claim still waits on it"
    assert_empty DataQuality::Review.reject([ other.id ], by: "human:test", reason: "not the licensee").first.errors
    assert record.reload.rejected?, "once no claim waits, rejecting retires the pending link the pipeline proposed"
  end

  test "a page the list stops linking keeps its stored read, so its facts aren't re-checked from it" do
    with = plugin(FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ]))
    run_stages(with, "crawl", "extract", "match")
    published = publish_link(DRESDEN_1, "05000010")
    page = Source.find_by!(url: DRESDEN_1)

    relist(list_html.sub("/facilities-safety/facility-finder/decommissioning/power-reactor/dresden-nuclear-power-station-unit-1",
      "/facilities-safety/facility-finder/decommissioning/power-reactor/cr3"))
    run_stages(with, "crawl", "extract")

    assert_equal page.reload.content_sha256, page.extracted_sha256, "extract leaves it alone"
    assert_nil page.extracted_rows_sha256
    assert_nil plugin.rows_sha256(page), "a page with no units has no rows to re-confirm"
    assert_equal [ published.id ], page.candidates.where(review_origin: "dropped").map(&:subject_id)
    dropped = page.candidates.find_by!(review_origin: "dropped")
    assert_match Plugin::UNLISTED, dropped.notes

    # A person keeps it; the next night's crawl doesn't ask again.
    assert_empty DataQuality::Review.approve([ dropped.id ], by: "human:test").first.errors
    Source.update_all(fetched_at: 2.days.ago)
    run_stages(with, "crawl")
    assert_equal 1, page.candidates.where(review_origin: "dropped").count
  end

  test "a list fetched while its site pages were blocked waits, proposing nothing, until they're read" do
    stub_request(:get, SITE_PAGES).to_return(status: 403, body: "Access Denied")
    with = plugin
    run_stages(with, "crawl")

    error = assert_raises(Plugin::SitePagesUnread) { run_stages(with, "extract") }
    assert_match "20 of 20 NRC site pages have no readable copy yet", error.message
    assert_equal 0, Candidate.count, "no unit comes in without its licensees"
    assert_nil list_source.extracted_sha256, "the list is extracted on a later run"

    # Next day NRC serves the pages again.
    stub_request(:get, SITE_PAGES).to_return(body: cr3_html)
    Source.update_all(fetched_at: 2.days.ago)
    run_stages(with, "crawl", "extract")

    assert_equal 21, Candidate.where(kind: "facility").count { |c| c.payload["nrc_docket"] }
  end

  test "a row with no site page link holds the whole list for a person: nothing withdrawn, nothing proposed" do
    with = plugin(FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ]))
    run_stages(with, "crawl", "extract", "match")
    dresden_page = Source.find_by!(url: DRESDEN_1)
    before = dresden_page.candidates.pluck(:id, :status)

    unlinked = list_html.sub(%r{<a href="/facilities-safety/facility-finder/decommissioning/power-reactor/dresden-nuclear-power-station-unit-1">(.*?)</a>}m, '\\1')
    assert_not_equal list_html, unlinked
    relist(unlinked)
    run_stages(with, "crawl")
    stats = CrawlRun.where(stage: "crawl").order(:id).last.stats

    assert_equal "a row has no site page link", stats["stopped"]
    assert list_source.crawl_needs_human?
    assert_match "Dresden – Unit 1, 05000010", list_source.status_reason
    assert_equal before, dresden_page.candidates.pluck(:id, :status), "the page's claims aren't withdrawn"

    # Extract on its own (the list's snapshot is stored) still proposes nothing from it.
    list_source.update!(crawl_status: "ok", extracted_sha256: nil)
    error = assert_raises(Plugin::SitePagesUnread) { plugin.extract(list_source, nil) }
    assert_match Plugin::LINK_MISSING, error.message
  end

  test "a page that names a new licensee: the old published link goes to a person, and stays published" do
    licensees = FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ])
    with = plugin(licensees)
    run_stages(with, "crawl", "extract", "match")
    duke = publish_link(CR3_URL, "05000302")

    # NRC rewrites the page: ADP is now the licensee named.
    stub_request(:get, CR3_URL).to_return(body: cr3_html.sub("Calendar year 2037", "Calendar year 2038"))
    licensees.answers = [ answer(ADP, "operates", ADP_ROLE_QUOTE) ]
    Source.update_all(fetched_at: 2.days.ago)
    run_stages(with, "crawl", "extract", "match")

    page = Source.find_by!(url: CR3_URL)
    assert page.candidates.status_matched.exists?(kind: "organization", payload: { "name" => ADP }), "the new licensee is proposed"
    flagged = page.candidates.where(review_origin: "dropped", subject_type: "FacilityRelationship")
    assert_equal [ duke.id ], flagged.map(&:subject_id), "the old link goes to a person"
    assert duke.reload.verified?, "never unpublished automatically"
  end

  test "a page someone cited by hand becomes this plug-in's, so its licensees are read" do
    Source.create!(url: CR3_URL, source_kind: "web_page", title: "Crystal River 3 (cited)")
    with = plugin(FakeLicensees.new([ answer("Duke", "owns", DUKE_QUOTE) ]))
    run_stages(with, "crawl", "extract")

    page = Source.find_by!(url: CR3_URL)
    assert_equal "nrc_decommissioning", page.source_kind
    assert page.candidates.exists?(kind: "facility_relationship"), "its licensee is read"
  end

  test "a page another plug-in reads holds the list, and isn't fetched here" do
    Source.create!(url: CR3_URL, source_kind: "nrc_reactor_list", title: "Another plug-in's")
    cr3 = stub_request(:get, CR3_URL).to_return(body: cr3_html)
    with = plugin
    run_stages(with, "crawl")

    assert_not_requested cr3
    assert_equal 1, CrawlRun.where(stage: "crawl").order(:id).last.stats.dig("site_pages", "another_kind")
    assert_raises(Plugin::SitePagesUnread) { run_stages(with, "extract") }
    assert_equal 0, Candidate.count
  end

  test "a list without its table needs a human" do
    stub_request(:get, Plugin::LIST_URL).to_return(body: "<html><body>We moved things around</body></html>")

    assert_equal 0, crawl.stats["units"]
    assert list_source.crawl_needs_human?
    assert_match "Couldn't find the decommissioning table", list_source.status_reason
    assert_not_requested @pages
  end

  test "proposes each row as a decommissioning unit, quoting the row" do
    source = stored(Plugin::LIST_URL, list_html)
    Plugin::List.rows(list_html).filter_map(&:page_url).uniq.each { |url| stored(url, cr3_html) }
    candidates = plugin.extract(source, nil)

    assert_equal 23, candidates.size, "21 units and 2 sites"
    assert candidates.all? { |candidate| candidate[:kind] == "facility" && plugin.quote_in_source?(source, candidate[:quote]) }
    sites, units = candidates.partition { |candidate| candidate[:payload]["nrc_docket"].nil? }
    assert_equal [ { "name" => "Indian Point", "facility_type" => "power_reactor", "status" => "decommissioning",
      "country_code" => "US", "city" => "Buchanan", "state" => "NY" }, "San Onofre" ], [ sites.first[:payload], sites.last[:payload]["name"] ]
    assert_equal candidates.first(2), sites, "sites come first, so match puts their units under them"
    by_docket = units.index_by { |candidate| candidate[:payload]["nrc_docket"] }
    assert_equal({ "name" => "Crystal River 3", "nrc_docket" => "05000302", "facility_type" => "power_reactor",
      "status" => "decommissioning", "country_code" => "US", "city" => "Crystal River", "state" => "FL",
      "aliases" => [ "Crystal River – Unit 3" ] }, by_docket["05000302"][:payload])
    assert_equal [ "San Onofre 2", "San Onofre 3" ], by_docket.values_at("05000361", "05000362").map { |c| c[:payload]["name"] }
    assert_nil by_docket["05000361"][:payload]["aliases"], "a name for two units is neither's alias"
    assert_equal [ "Crane 1", [ "Christopher M. Crane Clean Energy Center" ] ], by_docket["05000289"][:payload].values_at("name", "aliases")
    assert_equal [ "Duane Arnold 1", [ "Duane Arnold" ] ], by_docket["05000331"][:payload].values_at("name", "aliases")
    assert_equal [ "Three Mile Island 2", [ "Three Mile Island – Unit 2" ] ], by_docket["05000320"][:payload].values_at("name", "aliases")
    assert_equal [ "Kewaunee", nil ], by_docket["05000305"][:payload].values_at("name", "aliases")
  end

  test "a site page's licensees become companies with links to its unit" do
    stored(Plugin::LIST_URL, list_html)
    page = stored(CR3_URL, cr3_html)
    licensees = FakeLicensees.new([
      answer(ADP, "operates", ADP_QUOTE.sub("ADP-CR3", ADP), decommissions: true, decommissioning_quote: ADP_ROLE_QUOTE),
      answer("Duke", "owns", DUKE_QUOTE)
    ])

    candidates = plugin(licensees).extract(page, nil)

    assert_includes licensees.texts.first, "1.0 Site Identification"
    adp, adp_link, adp_role, duke, duke_link = candidates
    assert_equal [ "organization", { "name" => ADP } ], [ adp[:kind], adp[:payload] ]
    assert_equal "needs_review", adp[:status], "the quote isn't on the page as given"
    assert_match "isn't on the page", adp[:notes]
    assert_equal({ "organization" => { "name" => ADP }, "facility" => { "name" => "Crystal River 3", "nrc_docket" => "05000302" },
      "relationship_type" => "operates" }, adp_link[:payload])
    assert_equal [ "organization_role", { "organization" => { "name" => ADP }, "role" => "waste_decommissioning" }, ADP_ROLE_QUOTE, nil ],
      [ adp_role[:kind], adp_role[:payload], adp_role[:quote], adp_role[:status] ]
    assert_equal [ "Duke", DUKE_QUOTE, nil ], [ duke[:payload]["name"], duke[:quote], duke[:status] ]
    assert_equal "owns", duke_link[:payload]["relationship_type"]
    assert_equal 5, candidates.size, "no category for a company that doesn't decommission"
  end

  test "a quote that doesn't name the company goes to review" do
    stored(Plugin::LIST_URL, list_html)
    page = stored(CR3_URL, cr3_html)

    candidates = plugin(FakeLicensees.new([ answer("Accelerated Decommissioning Partners", "operates", ADP_QUOTE) ])).extract(page, nil)

    assert candidates.all? { |candidate| candidate[:status] == "needs_review" }
    assert_match "doesn't name the company", candidates.first[:notes]
  end

  test "a page the list no longer links to proposes nothing, and asks no model" do
    stored(Plugin::LIST_URL, list_html)
    page = stored("https://www.nrc.gov/facilities-safety/facility-finder/decommissioning/power-reactor/gone", cr3_html)
    licensees = FakeLicensees.new

    assert_empty plugin(licensees).extract(page, nil)
    assert_empty licensees.texts
  end

  test "a site page's rows hash ignores its date stamp" do
    stored(Plugin::LIST_URL, list_html)
    page = Source.new(url: CR3_URL, content_text: cr3_html)
    restamped = Source.new(url: CR3_URL, content_text: cr3_html.sub(/Thursday, August 27, 2026/, "Friday, October 16, 2026"))
    edited = Source.new(url: CR3_URL, content_text: cr3_html.sub("Calendar year 2037", "Calendar year 2038"))

    assert_not_equal cr3_html, restamped.content_text
    assert_equal plugin.rows_sha256(page), plugin.rows_sha256(restamped)
    assert_not_equal plugin.rows_sha256(page), plugin.rows_sha256(edited)
  end

  test "holds units with a restart plan, and TMI-2, for a person, and nothing else" do
    crane = Candidate.new(kind: "facility", payload: { "name" => "Crane 1", "nrc_docket" => "05000289" })
    duane = Candidate.new(kind: "facility", payload: { "name" => "Duane Arnold 1", "nrc_docket" => "05000331" })
    tmi2 = Candidate.new(kind: "facility", payload: { "name" => "Three Mile Island 2", "nrc_docket" => "05000320" })
    cr3 = Candidate.new(kind: "facility", payload: { "name" => "Crystal River 3", "nrc_docket" => "05000302" })
    link = Candidate.new(kind: "facility_relationship", payload: { "nrc_docket" => "05000289" })

    assert_match "Constellation plans to restart", plugin.hold_for_review(crane)
    assert_match "a restart plan is a note, never a status", plugin.hold_for_review(duane)
    assert_match "approving it shows its site as Decommissioning", plugin.hold_for_review(duane)
    assert_match "never under Crane", plugin.hold_for_review(tmi2)
    assert_nil plugin.hold_for_review(cr3)
    assert_nil plugin.hold_for_review(link)
  end

  test "a unit gone from the list is suggested as shut down" do
    payload, note = plugin.dropped("facility")

    assert_equal({ "status" => "shut_down" }, payload)
    assert_match "NRC no longer lists it", note
    assert_nil plugin.dropped("organization")
  end

  test "a site down to one listed unit stays proposed, so only its finished units are suggested as shut down" do
    with = plugin
    %w[crawl extract match].each { |stage| DataQuality::Pipeline.run("nrc_decommissioning", plugin: with, only: stage) }
    # As a person's approval leaves them: every claim decided, every unit and site live.
    list_source.candidates.update_all(status: "merged")
    Facility.update_all(verification_status: "verified", verified_by: "human:test")
    indian_point = Facility.find_by!(name: "Indian Point", parent_id: nil)

    # Units 1 and 2 finish; Unit 3 is still decommissioning.
    html = list_html.sub(%r{<tr>\s*<td><a href="[^"]*indian-point-unit-1">.*?</tr>\s*<tr>\s*<td><a href="[^"]*/ip2">.*?</tr>\s*}m, "")
    assert_equal 19, Plugin::List.rows(html).size
    list_source.update!(content_text: html, content_sha256: Digest::SHA256.hexdigest(html))
    %w[extract match].each { |stage| DataQuality::Pipeline.run("nrc_decommissioning", plugin: with, only: stage) }

    read = list_source.candidates.where(review_origin: nil)
    assert read.where(crawl_run_id: read.maximum(:crawl_run_id)).exists?(subject_type: "Facility", subject_id: indian_point.id),
      "the site is still listed"
    dropped = list_source.candidates.where(review_origin: "dropped").map { |candidate| Facility.find(candidate.subject_id).nrc_docket }
    assert_equal %w[05000003 05000247], dropped.sort, "only the finished units, never the site"
  end

  test "tells the verifier what the list states, and only for the list" do
    assert_match "status is decommissioning", plugin.source_facts(Source.new(url: Plugin::LIST_URL))
    assert_nil plugin.source_facts(Source.new(url: CR3_URL))
  end

  test "end to end: units under known sites, Crane, Duane Arnold and TMI-2 held, licensees linked" do
    Role.find_or_create_by!(key: "waste_decommissioning") { |role| role.name = "Waste and decommissioning" }
    dresden = Facility.create!(name: "Dresden Generating Station", facility_type: "power_reactor", country_code: "US",
      verification_status: "verified", verified_by: "human:test")
    # As the seed has them: Crane is TMI-1 renamed, and goes by its old names.
    crane_site = Facility.create!(name: "Crane Clean Energy Center", eia_plant_id: "8011", country_code: "US",
      verification_status: "verified", verified_by: "human:test")
    [ "Crane Clean Energy Center (Three Mile Island Unit 1)", "Three Mile Island Unit 1", "TMI-1" ].each { |name| crane_site.aliases.create!(alias: name) }
    duane_site = Facility.create!(name: "Duane Arnold Energy Center", facility_type: "power_reactor", state: "IA",
      country_code: "US", verification_status: "verified", verified_by: "human:test")
    licensees = FakeLicensees.new([ answer(ADP, "operates", ADP_QUOTE.sub("ADP-CR3 became", "#{ADP} became")) ])
    page_text = cr3_html.sub("ADP-CR3 became", "#{ADP} became")
    stub_request(:get, SITE_PAGES).to_return(body: page_text)
    with = plugin(licensees)

    %w[crawl extract match].each { |stage| DataQuality::Pipeline.run("nrc_decommissioning", plugin: with, only: stage) }
    DataQuality::Pipeline.run("nrc_decommissioning", plugin: with, only: "verify", verifier: PublishEverything.new)

    units = Candidate.where(kind: "facility").select { |candidate| candidate.payload["nrc_docket"] }.index_by { |candidate| candidate.payload["nrc_docket"] }
    assert_equal 21, units.size
    indian_point = Facility.find_by!(name: "Indian Point")
    assert_nil indian_point.parent_id
    assert_equal [ indian_point.id ] * 3, units.values_at("05000003", "05000247", "05000286").map { |c| Facility.find(c.subject_id).parent_id },
      "Indian Point's three units are one plant"
    assert_equal 3, Facility.where(parent_id: Facility.find_by!(name: "San Onofre").id).count
    assert_equal dresden.id, Facility.find(units["05000010"].subject_id).parent_id, "Dresden 1 goes under its site"
    crane = units["05000289"]
    assert_equal crane_site.id, Facility.find(crane.subject_id).parent_id
    assert crane.status_needs_review?
    assert_match "Constellation plans to restart", crane.notes
    duane = Facility.find(units["05000331"].subject_id)
    assert_equal [ "Duane Arnold 1", "05000331", duane_site.id ], [ duane.name, duane.nrc_docket, duane.parent_id ],
      "a unit under the site, never the site itself"
    assert_nil duane_site.reload.nrc_docket
    assert units["05000331"].status_needs_review?
    tmi2 = Facility.find(units["05000320"].subject_id)
    assert_not_equal crane_site.id, tmi2.parent_id, "TMI-2 is not part of Crane"
    assert_nil tmi2.parent_id
    assert units["05000320"].status_needs_review?
    assert_match "never under Crane", units["05000320"].notes
    assert_equal "recommend_publish", units["05000302"].ai_recommendation
    link = Candidate.where(kind: "facility_relationship").find { |c| c.payload.dig("facility", "nrc_docket") == "05000302" }
    assert link.subject_id, "the link to Crystal River 3 found both ends"

    # Approving a unit fills its site's blank status only when no other unit there differs.
    Facility.create!(name: "Dresden 2", nrc_docket: "05000237", parent: dresden, status: "operating", facility_type: "power_reactor",
      country_code: "US", verification_status: "verified", verified_by: "human:test")
    approved = DataQuality::Review.approve([ units["05000010"].id, units["05000331"].id ], by: "human:test")
    assert approved.all? { |result| result.errors.empty? }, approved.flat_map(&:errors).to_sentence
    assert_equal "decommissioning", Facility.find(units["05000010"].subject_id).status
    assert_nil dresden.reload.status, "Dresden 2 still runs, so the station isn't decommissioning"
    assert_equal "decommissioning", duane_site.reload.status, "Duane Arnold's one unit speaks for its site"
  end
end
