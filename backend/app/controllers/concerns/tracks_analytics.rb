# Analytics for controllers and views (#66): server-side events that skip
# bots, and whether a page gets the browser snippet. Bot filtering and path
# exclusions carried over from the usage counts in #62. See lib/analytics.rb.
#
#   track_search(params[:q], results: @results.size)
#   track_company_viewed(@company.slug)
module TracksAnalytics
  extend ActiveSupport::Concern
  include AdminVisitor

  # "Claude/" is the Claude app's built-in browser: our own agent sessions
  # browse the live site in a hidden pane, which sent page leaves without
  # page views (PostHog waits for a visible tab) and skewed the counts (#68).
  BOT_USER_AGENT = %r{bot|crawl|spider|slurp|scrap|fetch|preview|monitor|uptime|headless|lighthouse|
    curl|wget|python|ruby|java|go-http|okhttp|axios|node-fetch|httpclient|libwww|facebookexternalhit|claude/}ix
  # Not public pages: the admin, the design reference, the health check, Rails internals.
  UNTRACKED_PATHS = %r{\A/(admin|design|up|rails|assets|cable)(/|\z)}

  included do
    helper_method :analytics_snippet?
  end

  private
    def track_search(query, results:, source: "typed")
      return unless trackable_request?

      Analytics.track_search(query, results:, source:, visitor: visitor_properties)
      # Our own list of searches that found nothing (#483): the query only, never the visitor.
      SearchGap.record(query, results:)
    end

    def track_company_viewed(slug) = track("company_viewed", slug:)
    def track_power_plant_viewed(slug) = track("power_plant_viewed", slug:)

    # Only what the correction is about (its page, and the company or plant
    # on it), never the message or contact details.
    def track_correction_submitted(subject_type: nil, page_path: nil, record_type: nil, record_id: nil)
      track("correction_submitted", subject_type:, page_path:, record_type:, record_id:)
    end

    def track(event, properties)
      Analytics.capture(event, properties.compact.merge(visitor_properties)) if trackable_request?
    end

    # The visitor's country and whether they're internal (#205), from the
    # request's IP; the IP itself is never sent.
    def visitor_properties = GeoCountry.properties(request.remote_ip, admin: admin_visitor?)

    # Whether to load the browser snippet (page views) on this page.
    def analytics_snippet?
      Analytics.public_key.present? && request.get? && trackable_request?
    end

    def trackable_request?
      !bot? && !prefetch? && !request.path.match?(UNTRACKED_PATHS)
    end

    # Turbo's hover prefetch (X-Sec-Purpose) and the browser's own
    # (Sec-Purpose): a page fetched in case it's opened, not a view.
    def prefetch?
      [ request.headers["X-Sec-Purpose"], request.headers["Sec-Purpose"], request.headers["Purpose"] ]
        .any? { |value| value.to_s.include?("prefetch") }
    end

    def bot?
      user_agent = request.user_agent.to_s
      user_agent.blank? || user_agent.match?(BOT_USER_AGENT)
    end
end
