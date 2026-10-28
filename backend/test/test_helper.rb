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
    # A pending company reaches Today only with a sourced role (PM, 28 Oct).
    def give_sourced_role(company, key: "reactor_vendor")
      role = Role.find_by(key:) || Role.create!(key:, name: key.humanize)
      link = OrganizationRole.create!(organization: company, role:, verification_status: "pending")
      page = Source.find_or_create_by!(url: "https://example.com/role-source") { |s| s.source_kind = "web_page"; s.crawl_status = "ok"; s.content_sha256 = "r" }
      Evidence.create!(subject: link, source: page, quote: "#{company.name} designs reactors.", found_by: "human")
      company
    end

    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
