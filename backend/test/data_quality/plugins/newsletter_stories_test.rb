require "test_helper"

class DataQuality::Plugins::NewsletterStoriesTest < ActiveSupport::TestCase
  Plugin = DataQuality::Plugins::NewsletterStories
  TODAY = Date.new(2026, 11, 20)
  RELEASE = "https://www.acmefission.example/news/acme-signs-haleu-deal"
  DOE = "https://www.energy.gov/ne/articles/doe-awards-acme-fission"

  setup do
    Organization.create!(name: "Acme Fission", website: "https://www.acmefission.example", verification_status: "verified", verified_by: "human:tosin")
      .aliases.create!(alias: "Acme Fission")
    links = [ RELEASE, DOE, "https://www.ans.org/news/2026-11-19/acme", "https://www.acmefission.example/", "https://linkedin.com/company/acme",
      "https://www.othersite.example/news/x" ]
    Source.create!(url: "https://resend.com/emails/receiving/1", source_kind: "newsletters", crawl_status: "ok", fetched_at: TODAY.to_time,
      content_text: "Acme Fission signs a deal.#{DataQuality::Plugins::Newsletters::LINKS}#{links.join("\n")}")
    %w[www.acmefission.example www.energy.gov].each { |host| stub_request(:get, "https://#{host}/robots.txt").to_return(status: 404) }
  end

  def page(title, date, body) = %(<html><head><title>#{title}</title><meta property="article:published_time" content="#{date}"></head><body><p>#{body}</p></body></html>)
  def plugin = @plugin ||= Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY })

  test "follows only primary-source links (a directory company's page or a .gov page), never the newsletter's, a home page or social" do
    stub_request(:get, RELEASE).to_return(body: page("Acme Fission Signs HALEU Supply Deal", "2026-11-18", "Acme Fission signs a HALEU fuel supply deal."), headers: { "Content-Type" => "text/html" })
    stub_request(:get, DOE).to_return(body: page("DOE Awards Acme Fission Reactor Grant", "2026-11-17", "DOE awards Acme Fission a reactor grant."), headers: { "Content-Type" => "text/html" })
    stats = plugin.crawl(nil)
    assert_equal [ DOE, RELEASE ].sort, Source.where(source_kind: "newsletter_stories").pluck(:url).sort
    assert_equal 2, stats["fetched"]
    assert_equal 0, Plugin.new(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), today: -> { TODAY }).crawl(nil)["fetched"], "each page once"

    claims = Source.where(source_kind: "newsletter_stories").order(:url).flat_map { |source| plugin.extract(source, nil) }
    assert_equal [ "Acme Fission Signs HALEU Supply Deal", "DOE Awards Acme Fission Reactor Grant" ], claims.map { |claim| claim[:quote] }
    release = claims.first[:payload]
    assert_equal [ RELEASE, "2026-11-18", "Acme Fission", [ "Acme Fission" ] ], [ release["url"], release["published_on"], release["publisher"], release["about"].map { |a| a["name"] } ]
  end

  test "no claim without nuclear work, a directory name, or the page's own recent date" do
    source = ->(html) { Source.create!(url: "https://www.energy.gov/x/#{SecureRandom.hex(3)}", source_kind: "newsletter_stories", crawl_status: "ok", content_text: html) }
    assert_empty plugin.extract(source.(page("Acme Fission Opens Office", "2026-11-18", "Acme Fission opens an office.")), nil), "not nuclear"
    assert_empty plugin.extract(source.(page("DOE Funds Reactor Study", "2026-11-18", "A reactor study is funded.")), nil), "names nothing we have"
    assert_empty plugin.extract(source.(page("Acme Fission Reactor Milestone", "2026-09-01", "Acme Fission reactor.")), nil), "older than two weeks"
    assert_empty plugin.extract(source.(%(<html><head><title>Acme Fission Reactor</title></head><body>Acme Fission reactor.</body></html>)), nil), "no date of its own"

    Organization.create!(name: "Google", verification_status: "verified", verified_by: "human:tosin").aliases.create!(alias: "Google")
    @plugin = nil
    assert_empty plugin.extract(source.(page("Google Opens Data Center", "2026-11-18", "Google opens a data center near a nuclear plant.")), nil), "broad: nuclear once in passing"
    assert_equal 1, plugin.extract(source.(page("Google Signs Nuclear Power Deal", "2026-11-18", "Google signs a nuclear power deal.")), nil).size, "broad: nuclear in the title"
  end

  test "a Federal Register document is read through its API (#860)" do
    url = "https://www.federalregister.gov/documents/2026/11/18/2026-23456/acme-fission-reactor-construction-permit"
    Source.where(source_kind: "newsletters").update_all(content_text: "x#{DataQuality::Plugins::Newsletters::LINKS}#{url}")
    stub_request(:get, "https://www.federalregister.gov/robots.txt").to_return(status: 404)
    stub_request(:get, %r{\Ahttps://www\.federalregister\.gov/api/v1/documents/2026-23456\.json\?}).to_return(
      body: { title: "Acme Fission; Reactor Construction Permit Application", publication_date: "2026-11-18", abstract: "The NRC received Acme Fission's reactor application." }.to_json)
    plugin.crawl(nil)
    assert_not_requested :get, url
    claim = plugin.extract(Source.find_by!(url:), nil).sole
    assert_equal [ "Acme Fission; Reactor Construction Permit Application", "2026-11-18", "Federal Register" ], claim[:payload].values_at("title", "published_on", "publisher")
  end

  test "the quote is the page title even when only the head has it; an acronym-only page names its company (Copilot)" do
    Organization.create!(name: "TVA", verification_status: "verified", verified_by: "human:tosin").aliases.create!(alias: "TVA")
    @plugin = nil
    body = "The utility plans new reactors at Clinch River. " * 15
    html = %(<html><head><meta property="og:title" content="TVA Files Reactor Permit"><title>Home</title><meta property="article:published_time" content="2026-11-18"></head><body><p>#{body}</p></body></html>)
    source = Source.create!(url: "https://www.tva.gov/news/tva-files", source_kind: "newsletter_stories", crawl_status: "ok", content_text: html)
    claim = plugin.extract(source, nil).sole
    assert_equal "TVA Files Reactor Permit", claim[:quote]
    assert_includes claim[:payload]["about"].map { |hit| hit["name"] }, "TVA"
    assert plugin.quote_in_source?(source, claim[:quote]), "the head-only title counts as in the source"
    assert_includes plugin.verification_context(source, claim[:quote]), "Page title: TVA Files Reactor Permit"
  end
end
