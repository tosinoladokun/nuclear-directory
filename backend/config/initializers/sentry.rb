# Error reporting through Sentry (#55, Tosin's decision). Off unless SENTRY_DSN is set.
#
# Privacy rules, all enforced here:
# - no visitor IPs, cookies, request bodies or query strings (searches stay out)
# - request headers are allow-listed down to a few technical ones
# - no SQL query data and no job arguments
# - nothing runs without SENTRY_DSN, so development and tests send nothing
#
# sentry-ruby 7 replaced `send_default_pii` with `data_collection`. Its safe
# defaults come from the deprecated setting, so every category is set
# explicitly below rather than relying on them.
# The Sentry project also has "Prevent Storing of IP Addresses" turned on.
module ErrorReporting
  # Request headers worth keeping for debugging; everything else is filtered.
  # Anchored, because Sentry treats plain string terms as substrings (so
  # "accept" would also let through a client's "X-Accept-Visitor-Email").
  HEADERS = [ /\A(accept|content-type|content-length|x-request-id)\z/i ].freeze

  class << self
    def dsn = ENV["SENTRY_DSN"].presence

    def enabled? = !dsn.nil?

    # Applies the privacy rules and our defaults to a Sentry::Configuration.
    def configure(config)
      config.dsn = dsn
      # Render sets RENDER_GIT_COMMIT on every deploy.
      config.release = ENV["RENDER_GIT_COMMIT"].presence
      # Errors only; tracing would use up the free plan.
      config.traces_sample_rate = nil
      # Malformed request bodies from scanners: a 400 (BadRequestBody), never
      # worth an alert, wherever they surface.
      config.excluded_exceptions += [ "Rack::BadRequest" ]

      data = config.data_collection
      data.user_info = false
      data.cookies = false
      data.http_headers.request = Sentry::DataCollection::KeyValueCollection.new(mode: :allow_list, terms: HEADERS)
      data.http_headers.response = Sentry::DataCollection::KeyValueCollection.new(mode: :allow_list, terms: HEADERS)
      data.http_bodies = []
      data.url_query_params = false
      data.database_query_data = false
      data.queues = false
      data.graphql.document = false
      data.graphql.variables = false
      data.stack_frame_variables = false
      config
    end
  end
end

Sentry.init { |config| ErrorReporting.configure(config) } if ErrorReporting.enabled? && !Rails.env.test?
