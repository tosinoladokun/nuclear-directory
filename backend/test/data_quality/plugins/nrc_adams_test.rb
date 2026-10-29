require "test_helper"

# The answers are shaped from NRC's ADAMS Public Search API guide; the API
# needs a key the workstation doesn't have.
class DataQuality::Plugins::NrcAdamsTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NrcAdams
  TODAY = Date.new(2026, 10, 28)
  ANSWER = { "results" => [ { "document" => { "AccessionNumber" => "ML26290A001", "DocumentTitle" => "Kairos Power - Pre-Application Meeting Summary",
    "DocumentDate" => "2026-10-20", "DocumentType" => [ "Meeting Summary" ], "DocketNumber" => "99902069", "content" => "full text", "Url" => "https://adams-search.nrc.gov/ML26290A001" } } ] }.freeze

  setup do
    stub_request(:get, "https://adams-api.nrc.gov/robots.txt").to_return(status: 404)
    @search = stub_request(:post, Plugin::API_URL).with(headers: { "Ocp-Apim-Subscription-Key" => "k" }).to_return(body: ANSWER.to_json, headers: { "Content-Type" => "application/json" })
  end

  def plugin(key: "k") = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), key:, today: -> { TODAY })
  def crawl(key: "k") = DataQuality::Stages::Crawl.call(plugin: plugin(key:))

  test "is the plug-in for nrc_adams, and runs nightly" do
    assert_instance_of Plugin, DataQuality::Plugin.for("nrc_adams")
    assert_includes DataQuality::DailyCrawlJob::SOURCE_KINDS, "nrc_adams"
  end

  test "without a key it does nothing" do
    assert_equal({ "skipped" => Plugin::NO_KEY }, crawl(key: nil).stats)
    assert_not_requested @search
  end

  test "stores each search's documents' catalogue fields once a day, sending the key, proposing nothing" do
    assert_equal Plugin::SEARCHES.size, crawl.stats.values.count("changed")
    assert_equal Plugin::SEARCHES.size, crawl.stats.values.count("skipped_recent")
    assert_requested @search, times: Plugin::SEARCHES.size
    assert_requested(:post, Plugin::API_URL, times: Plugin::SEARCHES.size) { |request| JSON.parse(request.body)["filters"].last["value"] == "(DocumentDate ge '2026-10-14')" }

    source = Source.find_by!(url: "#{Plugin::API_URL}#pre-application")
    row = JSON.parse(source.content_text)
    assert_equal "ML26290A001", row["AccessionNumber"]
    refute row.key?("content"), "never the document's text"
    refute_includes source.content_text, "\"k\""
    assert_empty plugin.extract(source, nil)
  end

  test "a refused request is recorded" do
    stub_request(:post, Plugin::API_URL).to_return(status: 403, body: "Forbidden")
    assert_equal "blocked", crawl.stats.values.first
    assert Source.find_by!(url: "#{Plugin::API_URL}#pre-application").crawl_blocked?
  end

  test "robots' refusal needs a person at once; repeated blocks too" do
    stub_request(:get, "https://adams-api.nrc.gov/robots.txt").to_return(body: "User-agent: *\nDisallow: /\n")
    crawl
    assert Source.find_by!(url: "#{Plugin::API_URL}#pre-application").crawl_needs_human?
  end

  test "documents with unexpected fields keep their field names" do
    stub_request(:post, Plugin::API_URL).to_return(body: { "results" => [ { "accessionNumber" => "ML1" } ] }.to_json)
    crawl
    assert_equal({ "unexpected_fields" => [ "accessionNumber" ] }, JSON.parse(Source.find_by!(url: "#{Plugin::API_URL}#pre-application").content_text))
  end

  # The fixture is four real lines from production's first read (29 Oct).
  def stored = @stored ||= Source.create!(url: "#{Plugin::API_URL}#pre-application", source_kind: "nrc_adams_index", crawl_status: "ok",
    content_text: file_fixture("nrc_adams/pre-application.txt").read)

  def documents
    stored
    plugin.store_documents
    Source.where(source_kind: "nrc_adams").order(:id)
  end

  def document(text) = documents.find { |source| source.content_text.include?(text) }

  def known(*names)
    names.each do |name|
      company = Organization.find_by(slug: name.parameterize) || Organization.create!(name:)
      company.aliases.find_or_create_by!(alias: name)
      company.verify!(by: "human:tosin") unless company.verified?
    end
  end

  test "each developer document is its own source at its public PDF; operating-plant documents aren't stored" do
    assert_equal 3, documents.size
    assert documents.all? { |source| source.url.start_with?("https://www.nrc.gov/docs/") }
    assert_nil document("Palo Verde")
    assert_equal 0, plugin.store_documents, "written once"
  end

  test "a developer the directory has gets each document as separate evidence" do
    known("Radiant", "Arizona Public Service Co")
    claims = documents.flat_map { |source| plugin.extract(source, nil).map { |c| [ source.url, c ] } }

    radiant = claims.select { |_, c| c[:payload]["name"] == "Radiant" }
    assert_equal 2, radiant.map(&:first).uniq.size, "two accessions, two cited PDFs"
    assert claims.all? { |url, c| plugin.quote_in_source?(Source.find_by!(url:), c[:quote]) }
  end

  test "NRC assigning a project number to a company we have is one news item, never proposed twice" do
    known("The Leapfrog Group")
    letter = document("Assignment of Project Number")
    news = plugin.extract(letter, nil).select { |c| c[:kind] == "news_item" }.sole[:payload]

    assert_match "Assignment of Project Number", news["title"]
    assert_equal [ "U.S. Nuclear Regulatory Commission", "The Leapfrog Group" ], news["about"].map { |a| a["name"] }
    assert_equal "2026-10-19", news["published_on"]
    stage = plugin.extract(letter, nil).find { |c| c[:kind] == "licensing_stage" }[:payload]
    assert_equal({ "organization" => { "name" => "The Leapfrog Group" }, "stage" => "pre_application", "nrc_docket" => "99902187",
      "effective_on" => "2026-10-19" }, stage)

    Candidate.create!(source: letter, kind: "news_item", status: "rejected", quote: "x", payload: news)
    assert_empty plugin.extract(letter, nil).select { |c| c[:kind] == "news_item" }
  end

  test "a developer the directory doesn't have becomes a lead, not a claim" do
    assert_empty documents.flat_map { |source| plugin.extract(source, nil) }
    LeadSync.run
    assert Lead.exists?(name: "The Leapfrog Group")
    refute Lead.exists?(name: "Radiant"), "no company form in its name: not a lead"
    refute Lead.exists?(name: "Arizona Public Service Co"), "an operating plant's document isn't read"
  end

  test "an operating plant's 052 docket isn't a developer's" do
    assert Plugin.developer_docket?("05200025")
    Facility.create!(name: "Vogtle 3", nrc_docket: "05200025", status: "operating")
    refute Plugin.developer_docket?("05200025")
    assert Plugin.developer_docket?("99902187")
  end

  test "project-number news: only the last 60 days, at most 5 a read" do
    known("The Leapfrog Group")
    later = Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), key: "k", today: -> { Date.new(2027, 1, 30) })
    assert_empty later.extract(document("Assignment of Project Number"), nil).select { |c| c[:kind] == "news_item" }, "older than 60 days"
    assert_equal 5, Plugin::NEWS_PER_READ
  end

  test "the project-number letter's stage reaches the directory as a pending pre-application stage (#650)" do
    known("The Leapfrog Group")
    documents
    DataQuality::Stages::Extract.call(plugin:)
    run = DataQuality::Stages::Match.call(plugin:)
    assert_equal 0, run.stats["write_errors"]
    stage = LicensingStage.find_by!(nrc_docket: "99902187")
    assert_equal [ "pre_application", Date.new(2026, 10, 19), "pending" ], stage.values_at(:stage, :effective_on, :verification_status)
  end
end

