require "test_helper"
require_relative "../support/directory_builders"

class PagesTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  test "the privacy page says what analytics records, and that PostHog doesn't store IP addresses (#203)" do
    get privacy_path

    assert_select "meta[name=description][content*=?]", "dead clicks, the country you're visiting from"
    assert_select "h2#counts", "Analytics"
    assert_select "section[aria-labelledby=counts]", /how the site is used.*No cookies, and one visit isn't linked to the next.*no session recordings/m
    # #205: we look up the country and send only that; PostHog uses the IP to count visitors and drops it.
    assert_select "#counts ~ p", /which country you're in from your IP address, and adds only the country to the analytics/
    assert_select "#counts ~ p", /PostHog receives your IP address and browser with each request so it can count unique visitors without cookies. It doesn't store the IP address/
    assert_select "#counts ~ p a[href='https://db-ip.com']", "IP Geolocation by DB-IP"
    assert_select "#counts ~ p a[href='https://creativecommons.org/licenses/by/4.0/']", "CC BY 4.0"
    assert_select "#counts ~ p", /go through this site rather than straight to PostHog/
    assert_select "p", /Last updated\s+2026-10-12/
    assert_no_match(/set to discard IP addresses/, response.body)
  end

  test "privacy, disclaimer and the crawler page are linked from every page's footer" do
    get root_path
    assert_select "footer.nd-footer nav[aria-label='About this site']" do
      assert_select "a[href='/about']", "About"
      assert_select "a[href='/data']", "Data"
      assert_select "a[href='/privacy']", "Privacy"
      assert_select "a[href='/disclaimer']", "Disclaimer"
      assert_select "a[href='/bot']", "Our crawler"
      assert_select "a[href='mailto:hello@nuclear-directory.org']", "Contact us"
    end
    assert_select "footer.nd-footer p", count: 1, text: /\AHosting supported by Render\.\z/ do
      assert_select "a[href='https://render.com'][rel~=noopener]", "Render"
    end

    { about_path => "About", data_path => "Open data", privacy_path => "Privacy", disclaimer_path => "Disclaimer", bot_path => "NuclearDirectoryBot" }.each do |path, heading|
      get path
      assert_response :success
      assert_select "main", 1
      assert_select "h1", heading
      assert_select "meta[name=description]"
    end
  end

  test "the about page is in the sitemap and says it covers the US industry" do
    get sitemap_path
    assert_includes response.body, about_url
    get about_path
    assert_select "main", text: /US nuclear industry/
    assert_select "meta[name=description][content*='US nuclear industry']"
  end

  test "the data page describes the dataset and carries schema.org Dataset data for Dataset Search (#185)" do
    get data_path
    assert_response :success
    assert_select "link[rel=canonical][href=?]", data_url
    assert_select "main a[href='https://doi.org/10.5281/zenodo.23703377']", minimum: 1
    assert_select "main", text: /CC BY 4\.0/
    assert_select "main", text: /Companies: .*slug.*name/, minimum: 1

    ld = JSON.parse(css_select("script[type='application/ld+json']").first.text)
    assert_equal "Dataset", ld["@type"]
    assert_equal "https://doi.org/10.5281/zenodo.23703377", ld["identifier"]
    assert_equal "https://creativecommons.org/licenses/by/4.0/", ld["license"]
    assert_operator ld["description"].length, :>=, 50
    assert_equal StructuredDataHelper::PUBLISHED_TABLES.size * 2, ld["distribution"].size, "each published table as CSV and JSON"
    assert_empty StructuredDataHelper::PUBLISHED_TABLES - Dataset::Export::TABLES.keys, "only tables the export knows, so the schema list has their columns"
    assert_select "main a[href*=?]", "deal_terms", count: 0
    assert_select "main a[href*=?]", "licensing_stages", count: 0
    assert ld["distribution"].all? { |file| file["contentUrl"].start_with?("https://raw.githubusercontent.com/") }

    get sitemap_path
    assert_includes response.body, data_url
    get about_path
    assert_select "a[href=?]", data_path
  end

  test "the about page has the licences and the dataset DOI" do
    get about_path
    assert_select "a[href='https://doi.org/10.5281/zenodo.23703377']", "doi:10.5281/zenodo.23703377"
    assert_select "main", text: /MIT/
    assert_select "main", text: /CC BY 4\.0/
  end

  test "text pages have a skeleton: a summary, topic headings, a short lead, details as a list (#215)" do
    { about_path => %w[what checked licences cite thanks contact],
      data_path => %w[what download schema licence cite],
      privacy_path => %w[collect counts cookie corrections errors hosting contact],
      bot_path => %w[identity behaviour blocking contact],
      disclaimer_path => %w[sources currency advice endorsement mistakes] }.each do |path, sections|
      get path
      assert_select "h1 + p strong", "In short:"
      assert_equal sections, css_select("section h2").map { |h| h["id"] }
    end

    get privacy_path
    assert_equal [ "What we collect", "Analytics", "Cookies", "Corrections", "Error reports", "Hosting", "Questions" ], css_select("section h2").map(&:text)
    assert_select "section[aria-labelledby=counts] > p + ul li", 7
    get disclaimer_path
    assert_equal %w[Sources Accuracy Advice Endorsement Corrections], css_select("section h2").map(&:text)
  end

  test "text pages number what they cover and any steps, and link the companies they name" do
    get privacy_path
    assert_select "section[aria-labelledby=collect] ol li", 3
    { "PostHog" => "https://posthog.com/privacy", "Sentry" => "https://sentry.io/privacy/",
      "Render" => "https://render.com/privacy", "IP Geolocation by DB-IP" => "https://db-ip.com" }.each do |name, url|
      assert_select "main a[href=?][rel=noopener]", url, text: name
    end
    assert_no_match(/utm_/, response.body)

    get bot_path
    assert_select "section[aria-labelledby=blocking] ol li", 2
  end

  test "the crawler page shows the user agent the crawler actually sends" do
    get bot_path

    assert_select "pre", DataQuality::Fetcher::USER_AGENT
    assert_select "pre", /User-agent: NuclearDirectoryBot\s+Disallow: \//
    assert_equal [ "https://nuclear-directory.org/bot", DataQuality::Fetcher::CONTACT_EMAIL ],
      DataQuality::Fetcher::USER_AGENT[/\((.+)\)/, 1].delete_prefix("+").split("; ")
    assert_select "#contact + p a[href=?]", "mailto:#{DataQuality::Fetcher::CONTACT_EMAIL}"
  end

  test "the sitemap always lists Plants and sites, even with no public site yet" do
    get "/sitemap.xml"

    assert_includes response.body, "<loc>http://www.example.com/companies?category=plants</loc>"
  end

  test "company and plant pages carry lastmod: the latest change to them or anything their page shows" do
    company = organizations(:terrapower)
    company.verify!(by: "human:tosin") unless company.verified?
    company.update_columns(updated_at: Time.zone.parse("2026-01-02"))
    page = Source.create!(url: "https://example.com/lastmod", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: company, source: page, quote: "q", found_by: "human")
    other = Organization.create!(name: "Lastmod Partner", verification_status: "verified", verified_by: "human:tosin")
    link = Relationship.create!(from_organization: company, to_organization: other, relationship_type: "supplies", verification_status: "verified", verified_by: "human:tosin")
    link.update_columns(updated_at: Time.zone.parse("2026-10-20"))
    Rails.cache.clear

    get "/sitemap.xml"
    xml = Nokogiri::XML(response.body).remove_namespaces!
    url = xml.xpath("//url").find { |node| node.at("loc").text.end_with?("/companies/#{company.slug}") }
    assert url, "the company is listed"
    assert_operator Date.parse(url.at("lastmod").text), :>=, Date.new(2026, 10, 20), "its link's change counts"

    # A pending link (not shown) changed later doesn't move it.
    shown = url.at("lastmod").text
    pending = Organization.create!(name: "Pending Partner", verification_status: "verified", verified_by: "human:tosin")
    Relationship.create!(from_organization: company, to_organization: pending, relationship_type: "funds", verification_status: "pending")
      .update_columns(updated_at: 1.day.from_now)
    Rails.cache.clear
    get "/sitemap.xml"
    again = Nokogiri::XML(response.body).remove_namespaces!.xpath("//url").find { |node| node.at("loc").text.end_with?("/companies/#{company.slug}") }
    assert_equal shown, again.at("lastmod").text
  end

  test "lastmod follows a partner's rename, a term on a link and a new citation" do
    company = organizations(:terrapower)
    company.verify!(by: "human:tosin") unless company.verified?
    page = Source.create!(url: "https://example.com/lastmod2", source_kind: "web_page", crawl_status: "ok")
    Evidence.create!(subject: company, source: page, quote: "q", found_by: "human")
    company.update_columns(updated_at: Time.zone.parse("2026-01-02"))
    partner = Organization.create!(name: "Renamed Partner", verification_status: "verified", verified_by: "human:tosin")
    link = Relationship.create!(from_organization: company, to_organization: partner, relationship_type: "supplies", verification_status: "verified", verified_by: "human:tosin")
    [ link, partner ].each { |row| row.update_columns(updated_at: Time.zone.parse("2026-01-02")) }
    Evidence.where(subject: company).update_all(created_at: Time.zone.parse("2026-01-02"))
    date = lambda do
      Rails.cache.clear
      get "/sitemap.xml"
      Nokogiri::XML(response.body).remove_namespaces!.xpath("//url").find { |n| n.at("loc").text.end_with?("/companies/#{company.slug}") }.at("lastmod").text
    end
    base = date.call
    partner.update_columns(updated_at: Time.zone.parse("2026-02-01"))
    assert_equal "2026-02-01", date.call, "a partner's change shows on the page"
    DealTerm.create!(link:, term_type: "offtake", capacity_mw: 5, verification_status: "verified", verified_by: "human:tosin").update_columns(updated_at: Time.zone.parse("2026-03-01"))
    assert_equal "2026-03-01", date.call, "a term on its link"
    Evidence.create!(subject: company, source: page, quote: "q2", found_by: "human").update_columns(created_at: Time.zone.parse("2026-04-01"))
    assert_equal "2026-04-01", date.call, "a new citation"
    assert_operator base, :<, "2026-02-01"
  end

  test "the sitemap lists public companies and plants, not hidden ones" do
    cite!(company("Kairos Power", roles: [ role("reactor_vendor") ]))
    cite!(company("CFS", techs: [ technology("fusion") ]))
    company("Hidden Co", verified: false)
    company("Unpublished Co").unpublish!(by: "human:test")
    plant("Plant Vogtle")
    plant("Hidden Site", verified: false)

    get "/sitemap.xml"

    assert_response :success
    assert_equal "application/xml", response.media_type
    assert_includes response.body, "<loc>http://www.example.com/companies/kairos-power</loc>"
    assert_includes response.body, "<loc>http://www.example.com/plants/plant-vogtle</loc>"
    assert_includes response.body, "<loc>http://www.example.com/companies?category=reactor-developers</loc>"
    assert_includes response.body, "<loc>http://www.example.com/companies?tag=fusion</loc>"
    assert_not_includes response.body, "category=components", "an empty bucket isn't listed"
    assert_not_includes response.body, "tag=uranium"
    assert_includes response.body, "<loc>http://www.example.com/companies?category=plants</loc>"
    assert_includes response.body, "<lastmod>", "company and plant pages carry one"
    assert_not_includes response.body, "hidden"
    assert_not_includes response.body, "unpublished-co"
  end

  test "robots.txt keeps crawlers out of admin, forms and search, and points to the sitemap" do
    get "/robots.txt"

    assert_response :success
    assert_equal "text/plain", response.media_type
    %w[/admin /corrections /search /design].each { |path| assert_includes response.body, "Disallow: #{path}\n" }
    assert_includes response.body, "Sitemap: http://www.example.com/sitemap.xml"
  end

  test "robots.txt names the search and AI crawlers as allowed, each with the same disallows (#185)" do
    get "/robots.txt"

    groups = response.body.split("\n\n").to_h { |group| [ group[/User-agent: (.+)/, 1], group ] }
    %w[GPTBot OAI-SearchBot ChatGPT-User ClaudeBot Claude-SearchBot Claude-User PerplexityBot Perplexity-User Google-Extended Applebot-Extended].each do |agent|
      assert_includes groups.fetch(agent), "Allow: /\n", agent
      %w[/admin /corrections /search /design].each { |path| assert_includes groups.fetch(agent), "Disallow: #{path}", "#{agent} keeps out of #{path}" }
    end
    assert_not_includes groups.fetch("*"), "Allow: /"
  end

  test "llms.txt is a plain-text guide: what it covers, how facts are sourced, main pages, citing, corrections" do
    cite!(company("Kairos Power", roles: [ role("reactor_vendor") ]))
    cite!(plant("Hermes 2", facility_type: "power_reactor", status: "under_construction"))
    get "/llms.txt"

    assert_response :success
    assert_equal "text/plain", response.media_type
    body = response.body
    assert_match(/\A# Nuclear Directory\n\n> A directory of the organizations and facilities in the US nuclear industry/, body)
    assert_includes body, "- 1 companies:"
    assert_includes body, "- 1 plants and sites:"
    assert_includes body, "A fact with no public source is not published."
    assert_includes body, "[Developers](http://www.example.com/companies?category=reactor-developers)"
    assert_includes body, "(http://www.example.com/sitemap.xml)"
    assert_includes body, DirectoryHelper::CORRECTIONS_EMAIL
    assert_not_includes body, "—"
  end
end
