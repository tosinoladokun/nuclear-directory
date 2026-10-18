ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require_relative "test_helpers/session_test_helper"
require_relative "test_helpers/rate_limit_isolation"
require "webmock/minitest"

# No real HTTP in tests (e.g. to OpenRouter); stub it with WebMock.
WebMock.disable_net_connect!(allow_localhost: true)
# Nor real DNS: the fetcher's hosts all resolve to one public address
# (example.com's). SSRF tests pass their own resolver.
DataQuality::Fetcher.resolver = ->(_host) { [ "93.184.215.14" ] }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
