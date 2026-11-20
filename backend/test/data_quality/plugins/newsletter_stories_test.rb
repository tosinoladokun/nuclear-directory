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
  end
end
