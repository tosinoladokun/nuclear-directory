require "test_helper"
require "action_dispatch/middleware/host_authorization"
require "app_hosts"

# #147: production restricts to the hosts named in APP_HOSTS (set per
# service in render.yaml). Unset means no restriction, which is what CI's
# Lighthouse audit and a local production run need. Render's health check
# and the Sentry uptime monitor hit /up without our Host, so it has to
# stay 200 even when a list is set.
#
# The parsing lives in lib/app_hosts.rb so this test can exercise the
# same code production.rb runs — no duplicated literals that could drift.
class ProductionHostsTest < ActionDispatch::IntegrationTest
  EXCLUDE = ->(request) { request.path == "/up" }

  def status_for(hosts:, host:, path:)
    inner = ->(_env) { [ 200, {}, [ "ok" ] ] }
    middleware = ActionDispatch::HostAuthorization.new(inner, hosts, exclude: EXCLUDE)
    status, = middleware.call(Rack::MockRequest.env_for("http://#{host}#{path}", "HTTP_HOST" => host))
    status
  end

  test "APP_HOSTS parses a comma-separated list, trimming whitespace and blanks" do
    assert_equal %w[a.example b.example], AppHosts.from_env("APP_HOSTS" => "a.example, b.example,  ")
  end

  test "no APP_HOSTS means no restriction, which CI's Lighthouse and a local production run need" do
    assert_empty AppHosts.from_env({})
    assert_empty AppHosts.from_env("APP_HOSTS" => "")
  end

  test "an unknown host is refused when APP_HOSTS is set" do
    assert_equal 403, status_for(hosts: %w[nuclear-directory.org], host: "other.example", path: "/")
  end

  test "a host that's in APP_HOSTS is allowed" do
    assert_equal 200, status_for(hosts: %w[nuclear-directory.org www.nuclear-directory.org],
      host: "www.nuclear-directory.org", path: "/")
  end

  test "/up is excluded so Render and the uptime monitor still get 200" do
    assert_equal 200, status_for(hosts: %w[nuclear-directory.org], host: "unknown.example", path: "/up")
  end
end
