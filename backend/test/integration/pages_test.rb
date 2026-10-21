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
      assert_select "a[href='/privacy']", "Privacy"
      assert_select "a[href='/disclaimer']", "Disclaimer"
      assert_select "a[href='/bot']", "Our crawler"
      assert_select "a[href='mailto:hello@nuclear-directory.org']"
    end

    { privacy_path => "Privacy", disclaimer_path => "Disclaimer", bot_path => "NuclearDirectoryBot" }.each do |path, heading|
      get path
      assert_response :success
      assert_select "main", 1
      assert_select "h1", heading
      assert_select "meta[name=description]"
    end
  end

  test "text pages have a skeleton: a summary, topic headings, a short lead, details as a list (#215)" do
    { privacy_path => %w[collect counts cookie corrections errors hosting contact],
      bot_path => %w[identity behaviour blocking contact],
      disclaimer_path => %w[sources currency advice endorsement mistakes] }.each do |path, sections|
      get path
      assert_select "h1 + p strong", "In short:"
      assert_equal sections, css_select("section h2").map { |h| h["id"] }
    end

    get privacy_path
    assert_equal [ "What we collect", "Analytics", "Cookies", "Corrections", "Error reports", "Hosting", "Questions" ], css_select("section h2").map(&:text)
    assert_select "section[aria-labelledby=counts] > p + ul li", 5
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
    assert_not_includes response.body, "<lastmod>"
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
