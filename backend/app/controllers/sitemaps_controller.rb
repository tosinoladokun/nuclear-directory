# sitemap.xml, robots.txt (#56) and llms.txt (#185), built per request so the
# host is right on every deploy (preview URLs and the real domain alike).
class SitemapsController < ApplicationController
  def show
    pages = PublicPages.new
    @companies, @plants, @categories, @tags = pages.companies, pages.plants, pages.categories, pages.tags
    @company_lastmods, @plant_lastmods = pages.company_lastmods, pages.plant_lastmods
    expires_in 1.hour, public: true
  end

  # Search and AI crawlers are welcome: we want the directory cited (#185).
  # They are named so the choice is explicit and visible, and each group
  # repeats the disallows, since a named group replaces the * group for that bot.
  AI_CRAWLERS = %w[GPTBot OAI-SearchBot ChatGPT-User ClaudeBot Claude-SearchBot Claude-User PerplexityBot Perplexity-User
                   Google-Extended Applebot-Extended].freeze
  DISALLOWED = %w[/admin /corrections /search /design].freeze

  def robots
    expires_in 1.day, public: true
    return render plain: "User-agent: *\nDisallow: /\n" if Noindex.enabled?

    groups = [ "*", *AI_CRAWLERS ].map do |agent|
      "User-agent: #{agent}\n" + (agent == "*" ? "" : "Allow: /\n") + DISALLOWED.map { |path| "Disallow: #{path}\n" }.join
    end
    render plain: groups.join("\n") + "\nSitemap: #{sitemap_url}\n"
  end

  # A short plain-text guide for agents (llmstxt.org): what the site covers,
  # how its facts are sourced, the main pages and how to cite.
  def llms
    return head :not_found if Noindex.enabled?

    expires_in 1.hour, public: true
    pages = PublicPages.new
    render plain: render_to_string(partial: "sitemaps/llms", formats: [ :text ], locals: { companies: pages.companies.count, plants: pages.plants.count, categories: pages.categories })
  end
end
