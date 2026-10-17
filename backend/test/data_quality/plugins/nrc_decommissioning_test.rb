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
    assert_equal({ "list" => "changed", "units" => 21, "site_pages" => { "changed" => 20 } }, run.stats)
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
    assert dresden_page.candidates.all? { |c| c.status_rejected? && c.notes == Plugin::UNLISTED }, "the page Dresden 1 left speaks for nothing now"
    assert_equal dresden_page.candidates.count, run.stats["withdrawn"]
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
