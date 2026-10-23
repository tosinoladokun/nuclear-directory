require "test_helper"

# The fixture is NRC's real "Locations of Uranium Recovery Facilities" page,
# fetched 2026-10-18 with the plug-in's Fetcher and cut to its main content.
class DataQuality::Plugins::NrcUraniumRecoveryTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcUraniumRecovery
  CROW_BUTTE = "Crow Butte | Crow Butte Resources, Inc. | Chadron, Nebraska | In Situ Recovery (ISR)"

  setup do
    stub_request(:get, "https://www.nrc.gov/robots.txt").to_return(body: file_fixture("nrc/robots.txt").read)
    @page = stub_request(:get, Plugin::PAGE_URL).to_return(body: html)
  end

  def html = file_fixture("nrc/uranium/list.html").read
  def plugin = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }))
  def crawl = DataQuality::Stages::Crawl.call(plugin:)
  def page_source = Source.find_by!(url: Plugin::PAGE_URL)
  def stored(content = html) = Source.create!(url: Plugin::PAGE_URL, source_kind: "nrc_uranium_recovery", crawl_status: "ok",
    content_text: content, content_sha256: Digest::SHA256.hexdigest(content))

  test "is the plug-in for nrc_uranium_recovery" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_uranium_recovery")
  end

  test "crawls the page once a day and counts the NRC-licensed sites" do
    run = crawl
    second = crawl

    assert_equal({ "page" => "changed", "sites" => 3 }, run.stats)
    assert_equal "skipped_recent", second.stats["page"]
    assert_requested @page, times: 1
  end

  test "a blocked page stops the crawl" do
    stub_request(:get, Plugin::PAGE_URL).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)

    assert_equal({ "page" => "blocked", "stopped" => "page blocked" }, crawl.stats)
    assert page_source.crawl_blocked?
  end

  test "a page without the NRC-licensed table needs a human, and extracts nothing" do
    stub_request(:get, Plugin::PAGE_URL).to_return(body: "<html><body><p>We moved things around.</p></body></html>")

    assert_equal 0, crawl.stats["sites"]
    assert page_source.crawl_needs_human?
    assert_raises(Plugin::TableMissing) { plugin.extract(page_source, nil) }
  end

  test "each NRC-licensed site gives the site and its licensee, quoting its row; no link or role (DQ, 22 Oct)" do
    source = stored
    candidates = plugin.extract(source, nil)

    assert_equal 6, candidates.size
    assert candidates.all? { |c| plugin.quote_in_source?(source, c[:quote]) }
    crow_butte = candidates.select { |c| c[:quote] == CROW_BUTTE }
    assert_equal [
      { kind: "facility", quote: CROW_BUTTE, payload: { "name" => "Crow Butte", "facility_type" => "uranium_mine",
        "country_code" => "US", "city" => "Chadron", "state" => "NE" } },
      { kind: "organization", quote: CROW_BUTTE, payload: { "name" => "Crow Butte Resources, Inc." } }
    ], crow_butte
    sites = candidates.select { |c| c[:kind] == "facility" }.map { |c| c[:payload].values_at("name", "state") }
    assert_equal [ [ "Crow Butte", "NE" ], [ "Crownpoint", "NM" ], [ "Dewey Burdock", "SD" ] ], sites
  end

  test "the Agreement States' table isn't read: NRC no longer vouches for it" do
    names = plugin.extract(stored, nil).filter_map { |c| c[:payload]["name"] }

    assert_not_includes names, "Lost Creek / LC East/KM Horizon"
    assert_not_includes names, "Smith Ranch"
  end

  test "a site in counties has no city, and a row it can't read is held for a person after match" do
    counties = html.sub("Chadron, Nebraska", "Dawes County, Nebraska").sub("Crownpoint, New Mexico", "Crownpoint, Atlantis")
      .sub(">In Situ Recovery (ISR)</a>", ">Heap Leach</a>")
    candidates = plugin.extract(stored(counties), nil).select { |c| c[:kind] == "facility" }
    held = ->(c) { plugin.hold_for_review(Candidate.new(kind: c[:kind], payload: c[:payload], quote: c[:quote])) }

    crow_butte, crownpoint, dewey = candidates
    assert candidates.none? { |c| c[:status] }, "all go through match first"
    assert_nil crow_butte[:payload]["city"]
    assert_equal "NE", crow_butte[:payload]["state"]
    assert_nil crow_butte[:payload]["facility_type"]
    assert_match "type of facility", held.(crow_butte)
    assert_match "state", held.(crownpoint)
    assert_nil held.(dewey)
  end

  test "the rows hash covers the NRC-licensed table only" do
    a = Source.new(url: Plugin::PAGE_URL, content_text: html)
    b = Source.new(url: Plugin::PAGE_URL, content_text: html.sub("Smith Ranch", "Smith Ranch-Highland"))
    c = Source.new(url: Plugin::PAGE_URL, content_text: html.sub("NuFuels, Inc.", "NuFuels, LLC"))

    assert_equal plugin.rows_sha256(a), plugin.rows_sha256(b)
    assert_not_equal plugin.rows_sha256(a), plugin.rows_sha256(c)
  end

  test "tells the verifier what the table states" do
    facts = plugin.source_facts(Source.new(url: Plugin::PAGE_URL))

    assert_match "NRC-licensed uranium recovery facilities", facts
    assert_match "Licensee", facts
  end

  test "end to end: a seed site with a similar name goes to review, not duplicated" do
    Role.find_or_create_by!(key: "mining") { |role| role.name = "Mining and milling" }
    seed = Facility.create!(name: "Crow Butte ISR operation", facility_type: "uranium_mine", country_code: "US",
      verification_status: "verified", verified_by: "human:test")

    %w[crawl extract match].each { |stage| DataQuality::Pipeline.run("nrc_uranium_recovery", plugin:, only: stage) }

    crow_butte = Candidate.find_by!(kind: "facility", payload: { "name" => "Crow Butte", "facility_type" => "uranium_mine",
      "country_code" => "US", "city" => "Chadron", "state" => "NE" })
    assert crow_butte.status_needs_review?, "similar to #{seed.name}: a person decides"
    assert_equal 1, Facility.where("name ILIKE ?", "Crow Butte%").count
    dewey = Candidate.where(kind: "facility").find { |c| c.payload["name"] == "Dewey Burdock" }
    assert dewey.status_matched?, "a new site is proposed as pending"
  end

  test "a page someone cited by hand becomes this plug-in's, so it's extracted" do
    Source.create!(url: Plugin::PAGE_URL, source_kind: "web_page", title: "NRC uranium recovery (cited)")

    %w[crawl extract].each { |stage| DataQuality::Pipeline.run("nrc_uranium_recovery", plugin:, only: stage) }

    assert_equal "nrc_uranium_recovery", page_source.source_kind
    assert_equal 6, page_source.candidates.count
  end

  test "a site gone from an approved table of three goes to a person, with its licensee" do
    Role.find_or_create_by!(key: "mining") { |role| role.name = "Mining and milling" }
    %w[crawl extract match].each { |stage| DataQuality::Pipeline.run("nrc_uranium_recovery", plugin:, only: stage) }
    %w[facility organization].each do |kind|
      Candidate.where(kind:).order(:id).each do |claim|
        result = DataQuality::Review.approve([ claim.id ], by: "human:test").first
        assert_empty result.errors, "approving #{kind} #{claim.payload}"
      end
    end

    # NRC drops Dewey Burdock from the table.
    doc = Nokogiri::HTML(html)
    doc.at_css(%(table[summary="#{Plugin::TABLE_SUMMARY}"])).css("tr").find { |row| row.text.include?("Dewey Burdock") }.remove
    stub_request(:get, Plugin::PAGE_URL).to_return(body: doc.to_html)
    Source.update_all(fetched_at: 2.days.ago)
    %w[crawl extract match].each { |stage| DataQuality::Pipeline.run("nrc_uranium_recovery", plugin:, only: stage) }

    flagged = page_source.candidates.where(review_origin: "dropped")
    assert_equal %w[facility organization], flagged.map(&:kind).sort
    assert flagged.all? { |c| c.quote.include?("Dewey Burdock") }
    assert Facility.find_by!(name: "Dewey Burdock").verified?, "nothing is unpublished; a person decides"
  end

  test "one unreadable row among good ones holds the whole read: nothing is written, nothing looks dropped" do
    blanked = html.sub("Powertech Uranium Corporation", "")
    stub_request(:get, Plugin::PAGE_URL).to_return(body: blanked)

    stats = crawl.stats
    assert_equal({ "page" => "changed", "sites" => 2, "unreadable_rows" => 1 }, stats)
    assert page_source.crawl_needs_human?
    assert_match Plugin::ROW_UNREADABLE, page_source.status_reason
    error = assert_raises(Plugin::TableMissing) { plugin.extract(page_source, nil) }
    assert_match Plugin::ROW_UNREADABLE, error.message
  end
end
