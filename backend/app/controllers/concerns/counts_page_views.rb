# Counts a page view for each successful page a person loads (#45). Only the
# path is recorded, never the query string, cookies, IP or user agent.
#
# Not counted: bots, the /design reference page, the health check, anything
# that isn't a full HTML page (assets, JSON, Turbo Frame requests), and
# Turbo's hover prefetches, which load a page the person may never open.
module CountsPageViews
  extend ActiveSupport::Concern

  BOT_USER_AGENT = /bot|crawl|spider|slurp|scrap|fetch|preview|monitor|uptime|headless|lighthouse|
    curl|wget|python|ruby|java|go-http|okhttp|axios|node-fetch|httpclient|libwww|facebookexternalhit/ix
  IGNORED_PATHS = %r{\A/(design|up|rails|assets|cable)(/|\z)}

  included do
    after_action :count_page_view
  end

  private
    def count_page_view
      return unless countable_page_view?

      UsageCount.track_page_view(request.path.chomp("/").presence || "/")
    rescue => error
      # Counting must never break a page.
      Rails.logger.warn("[usage] page view not counted: #{error.class}: #{error.message}")
    end

    def countable_page_view?
      request.get? && response.status == 200 && response.media_type == "text/html" &&
        request.headers["Turbo-Frame"].blank? && !prefetch? && !bot? && !request.path.match?(IGNORED_PATHS)
    end

    def prefetch?
      [ request.headers["Sec-Purpose"], request.headers["Purpose"], request.headers["X-Sec-Purpose"] ]
        .compact.any? { |value| value.include?("prefetch") }
    end

    def bot?
      user_agent = request.user_agent.to_s
      user_agent.blank? || user_agent.match?(BOT_USER_AGENT)
    end
end
