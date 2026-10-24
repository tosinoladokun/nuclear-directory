# Anonymous product analytics through PostHog (#66, Tosin's decision).
#
# Privacy rules, all enforced here:
# - nobody is ever identified: every event uses one shared distinct id, never
#   identify(), and no person profiles are created
# - no personal data in properties, and never an IP: sent from the server,
#   PostHog would see ours. TracksAnalytics adds the visitor's country and
#   internal flag instead (GeoCountry, #205), and $geoip_disable keeps
#   PostHog's own lookup from replacing them. (PostHog's cookieless mode
#   strips the IP from browser events before anything is stored: #48660.)
# - nothing runs without POSTHOG_API_KEY, and nothing is sent in tests
#
# Server-side events (controllers call these through TracksAnalytics, which
# also skips bots):
#   Analytics.track_search(params[:q], results: results.size)
#   Analytics.capture("company_viewed", slug: company.slug)
#
# Page views come from the browser snippet (app/javascript/analytics.js),
# configured in the same cookieless way.
module Analytics
  EVENTS = %w[search company_viewed power_plant_viewed correction_submitted].freeze
  # One id for everyone: events are counted, never tied to a visitor.
  DISTINCT_ID = "anonymous"
  ANONYMOUS = { "$process_person_profile" => false, "$geoip_disable" => true, "$ip" => nil }.freeze
  DEFAULT_HOST = "https://us.i.posthog.com"
  MAX_QUERY_LENGTH = 200
  # Where a search came from: typed in a field, or a suggested search on the
  # home page, so suggestions don't count as demand for themselves.
  SEARCH_SOURCES = %w[typed suggestion].freeze

  class << self
    # A PostHog::Client, or nil when analytics is off. Tests assign a fake.
    attr_writer :client

    def client
      return @client if defined?(@client)

      @client = build_client
    end

    def enabled? = !client.nil?

    # The project key (for the browser snippet) and the server client's host;
    # the browser goes through /relay instead (#205).
    def public_key = (api_key if enabled?)
    def host = ENV["POSTHOG_HOST"].presence || DEFAULT_HOST

    # Sends one anonymous event. An unknown event name is a programming error
    # and raises; anything that goes wrong sending it never does, since
    # analytics must not break a page.
    def capture(event, properties = {})
      raise ArgumentError, "unknown analytics event #{event.inspect}" unless EVENTS.include?(event.to_s)
      return unless enabled?

      begin
        client.capture(distinct_id: DISTINCT_ID, event: event.to_s, properties: properties.stringify_keys.merge(ANONYMOUS))
      rescue => error
        Rails.logger.warn("[analytics] #{event} not sent: #{error.class}: #{error.message}")
        nil
      end
    end

    # The search interface Design calls (same as #62's). Queries are
    # normalized so "TerraPower " and "terrapower" count together, and
    # zero-result searches are flagged so they're easy to find.
    # visitor: the country and internal flag (TracksAnalytics#visitor_properties).
    # source: "typed" or "suggestion"; anything else counts as typed.
    def track_search(query, results:, source: "typed", visitor: {})
      normalized = normalize_query(query) or return
      source = SEARCH_SOURCES.include?(source.to_s) ? source.to_s : "typed"

      capture("search", { query: normalized, results: results.to_i, zero_results: results.to_i.zero?, source: }.merge(visitor))
    end

    def normalize_query(query)
      query.to_s.unicode_normalize(:nfkc).downcase.squish.first(MAX_QUERY_LENGTH).presence
    end

    private
      def api_key = ENV["POSTHOG_API_KEY"].presence

      def build_client
        return if Rails.env.test? || api_key.nil?

        PostHog::Client.new(api_key: api_key, host: host,
          on_error: proc { |status, error| Rails.logger.warn("[analytics] PostHog error #{status}: #{error}") })
      end
  end
end
