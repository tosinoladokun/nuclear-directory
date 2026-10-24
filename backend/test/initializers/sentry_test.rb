require "test_helper"

class ErrorReportingTest < ActiveSupport::TestCase
  REQUEST = {
    "REQUEST_METHOD" => "POST",
    "rack.url_scheme" => "https",
    "HTTP_HOST" => "nuclear-directory.org",
    "PATH_INFO" => "/companies/terrapower/corrections",
    "QUERY_STRING" => "q=jane+doe",
    "REMOTE_ADDR" => "203.0.113.7",
    "HTTP_X_FORWARDED_FOR" => "198.51.100.23",
    "HTTP_X_REAL_IP" => "198.51.100.23",
    "HTTP_TRUE_CLIENT_IP" => "198.51.100.23",
    "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh)",
    "HTTP_REFERER" => "https://example.com/?email=jane@example.com",
    "HTTP_COOKIE" => "_nuclear_directory_session=abc123",
    "HTTP_ACCEPT" => "text/html",
    "HTTP_X_ACCEPT_VISITOR_EMAIL" => "visitor@example.com",
    "CONTENT_TYPE" => "application/x-www-form-urlencoded",
    "action_dispatch.request_id" => "req-42",
    "rack.input" => StringIO.new("email=jane%40example.com&note=hello")
  }.freeze

  def event_for(env)
    config = ErrorReporting.configure(Sentry::Configuration.new)
    event = Sentry::ErrorEvent.new(configuration: config)
    event.rack_env = env.dup
    event.to_h
  end

  test "events carry no IP, cookies, body, query string or identifying headers" do
    event = event_for(REQUEST)
    request = event[:request]
    sent = event.to_json

    assert_empty event[:user].to_h
    assert_nil request[:data]
    assert_nil request[:query_string]
    assert_empty request[:cookies].to_h
    [ "203.0.113.7", "198.51.100.23", "jane", "visitor@", "abc123", "Mozilla" ].each do |value|
      assert_not_includes sent, value
    end
  end

  test "a few technical headers are kept for debugging" do
    headers = event_for(REQUEST)[:request][:headers]

    assert_equal "text/html", headers["Accept"]
    assert_equal "req-42", headers["X-Request-Id"]
    assert_equal "[Filtered]", headers["User-Agent"]
    assert_equal "[Filtered]", headers["X-Accept-Visitor-Email"], "allow-list must match whole header names"
  end

  test "it is off without SENTRY_DSN" do
    with_env("SENTRY_DSN" => nil) { assert_not ErrorReporting.enabled? }
    with_env("SENTRY_DSN" => "https://public@o0.ingest.sentry.io/0") { assert ErrorReporting.enabled? }
  end

  test "malformed request bodies are never reported" do
    config = ErrorReporting.configure(Sentry::Configuration.new)
    assert config.exception_class_allowed?(RuntimeError.new("boom"))
    refute config.exception_class_allowed?(Rack::Multipart::BoundaryTooLongError.new("multipart boundary size too large (71 characters)"))
    refute config.exception_class_allowed?(Rack::Multipart::EmptyContentError.new)
  end

  private
    def with_env(values)
      saved = values.keys.index_with { |key| ENV[key] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      saved.each { |key, value| ENV[key] = value }
    end
end
