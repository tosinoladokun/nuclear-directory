require "test_helper"
require "action_dispatch/middleware/host_authorization"

# #147: production restricts to our own domains and lets Render's health
# check and the Sentry uptime monitor through on /up. The behavior lives in
# Rails's HostAuthorization middleware; this test runs it against the
# production hosts list to confirm the end result, without booting
# production.rb (which would need production secrets).
#
# Keep the HOSTS and EXCLUDE values below in sync with
# config/environments/production.rb.
class ProductionHostsTest < ActionDispatch::IntegrationTest
  HOSTS = %w[nuclear-directory.org www.nuclear-directory.org].freeze
  EXCLUDE = ->(request) { request.path == "/up" }

  def status_for(host:, path:)
    inner = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = ActionDispatch::HostAuthorization.new(inner, HOSTS, exclude: EXCLUDE)
    status, = middleware.call(Rack::MockRequest.env_for("http://#{host}#{path}"))
    status
  end

  test "an unknown host is refused" do
    assert_equal 403, status_for(host: "other.example", path: "/")
  end

  test "our own domains are allowed" do
    HOSTS.each { |host| assert_equal 200, status_for(host:, path: "/"), host }
  end

  test "/up is excluded so Render and the uptime monitor still get 200" do
    assert_equal 200, status_for(host: "unknown.example", path: "/up")
  end
end
