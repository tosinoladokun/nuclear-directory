require "test_helper"
require_relative "../support/fake_geo_reader"

# /relay/* (#205): the browser's PostHog traffic through our site, with the
# visitor's country added and the IP never put into an event.
class RelayTest < ActionDispatch::IntegrationTest
  include GeoCountryTestHelper

  VISITOR = "81.2.69.142"
  BROWSER = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

  # Both rate-limit stores are process-wide; test_helpers/rate_limit_isolation
  # clears them (and Rails.cache) before every integration test (#220), so
  # another test signing in to the admin can't use up this one's quota.

  def send_events(body, path: "/relay/e/?ip=0&ver=1.438.7", ip: VISITOR, headers: {})
    post path, params: body.is_a?(String) ? body : body.to_json,
      headers: { "Content-Type" => "text/plain", "User-Agent" => BROWSER }.merge(headers),
      env: { "REMOTE_ADDR" => ip }
  end

  def forwarded_events(request) = Array.wrap(JSON.parse(request.body).then { |b| b.is_a?(Hash) && b["batch"] ? b["batch"] : b })

  test "an event gets the visitor's country, loses any IP, and goes to PostHog with the browser's details" do
    forwarded = nil
    stub_request(:post, "https://us.i.posthog.com/e/?ip=0&ver=1.438.7").with { |request| forwarded = request }
      .to_return(status: 200, body: '{"status":1}', headers: { "Content-Type" => "application/json", "Set-Cookie" => "ph=1" })

    send_events({ event: "$pageview", properties: { "$current_url" => "https://nuclear-directory.org/", "$ip" => VISITOR } })

    assert_response :success
    assert_equal '{"status":1}', response.body
    assert_nil response.headers["Set-Cookie"], "no cookies back"
    props = forwarded_events(forwarded).sole["properties"]
    assert_equal [ "GB", "United Kingdom", true ], props.values_at("$geoip_country_code", "$geoip_country_name", "$geoip_disable")
    assert_not props.key?("$ip")
    assert_not_includes forwarded.body, VISITOR, "the IP is never in what's sent"
    # Only for PostHog's cookieless visitor count, which hashes it and drops it (#48660).
    assert_equal VISITOR, forwarded.headers["X-Forwarded-For"]
    assert_equal BROWSER, forwarded.headers["User-Agent"]
    assert_nil forwarded.headers["Cookie"], "no cookies forward"
  end

  test "a batch gets the country on every event" do
    forwarded = nil
    stub_request(:post, "https://us.i.posthog.com/batch/").with { |request| forwarded = request }.to_return(status: 200, body: "{}")

    send_events({ batch: [ { event: "$pageview", properties: {} }, { event: "$pageleave" } ] }, path: "/relay/batch/")

    assert_equal [ "GB", "GB" ], forwarded_events(forwarded).map { |e| e["properties"]["$geoip_country_code"] }
  end

  test "events from an internal address are tagged, for PostHog's test-account filter" do
    internal_ips!(VISITOR)
    forwarded = nil
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).with { |request| forwarded = request }.to_return(status: 200, body: "{}")

    send_events({ event: "$pageview", properties: {} })

    assert_equal true, forwarded_events(forwarded).sole["properties"]["internal"]
  end

  def internal_flags(sent) = sent.map { |request| forwarded_events(request).sole["properties"]["internal"] }

  test "a browser that signed in to the admin stays internal after signing out, whatever its IP" do
    sent = []
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).with { |request| sent << request }.to_return(status: 200, body: "{}")

    send_events({ event: "$pageview", properties: {} })
    post session_path, params: { email_address: users(:admin).email_address, password: "correct horse battery staple" }
    send_events({ event: "$pageview", properties: {} }, ip: "8.8.8.8")
    delete session_path
    send_events({ event: "$pageview", properties: {} }, ip: "203.0.113.9")

    assert_equal [ nil, true, true ], internal_flags(sent)
    assert sent.none? { |request| request.headers["Cookie"] }, "the admin's cookies never go to PostHog"
  end

  test "a session from before the internal cookie still counts; a made-up cookie doesn't" do
    sent = []
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).with { |request| sent << request }.to_return(status: 200, body: "{}")

    cookies["nd_internal"] = "1" # unsigned: forged
    cookies["session_id"] = "made-up"
    send_events({ event: "$pageview", properties: {} })
    cookies.delete("nd_internal")
    sign_in_as users(:admin)
    send_events({ event: "$pageview", properties: {} })

    assert_equal [ nil, true ], internal_flags(sent)
  end

  test "the visitor's IP goes only with events, not script downloads" do
    stub_request(:get, "https://us-assets.i.posthog.com/static/array.js").to_return(status: 200, body: "")

    get "/relay/static/array.js", env: { "REMOTE_ADDR" => VISITOR }

    assert_requested(:get, "https://us-assets.i.posthog.com/static/array.js") { |request| request.headers["X-Forwarded-For"].nil? }
  end

  test "a body the country pushes past the cap is refused" do
    stub_const(RelayController, :MAX_BODY, 2_000) do
      send_events({ batch: Array.new(100) { {} } }, path: "/relay/batch/")
    end

    assert_response :content_too_large
    assert_not_requested :any, /posthog\.com/
  end

  test "scripts come from PostHog's asset host" do
    stub_request(:get, "https://us-assets.i.posthog.com/static/array.js").to_return(status: 200, body: "/* js */",
      headers: { "Content-Type" => "application/javascript", "Cache-Control" => "public, max-age=3600" })

    get "/relay/static/array.js"

    assert_response :success
    assert_equal "/* js */", response.body
    assert_equal %w[max-age=3600 public], response.headers["Cache-Control"].split(", ").sort
  end

  test "only PostHog's capture, flag and script paths are passed on" do
    [ "/relay/api/projects/1/", "/relay/../admin", "/relay/static/../../etc" ].each do |path|
      get path
      assert_response :not_found, path
    end
    assert_not_requested :any, /posthog\.com/
  end

  test "a body over 1 MB is refused" do
    send_events("x" * (RelayController::MAX_BODY + 1))

    assert_response :content_too_large
    assert_not_requested :any, /posthog\.com/
  end

  test "a page leave sent as a beacon (base64 form) gets the country and internal tag too" do
    internal_ips!(VISITOR)
    forwarded = nil
    stub_request(:post, "https://us.i.posthog.com/e/?compression=base64").with { |request| forwarded = request }
      .to_return(status: 200, body: "{}")
    event = { event: "$pageleave", properties: { "$current_url" => "https://nuclear-directory.org/" } }
    beacon = "data=#{URI.encode_www_form_component(Base64.strict_encode64(event.to_json))}"

    send_events(beacon, path: "/relay/e/?compression=base64", headers: { "Content-Type" => "application/x-www-form-urlencoded" })

    assert_response :success
    assert forwarded.body.start_with?("data="), "sent on in the same format"
    sent = JSON.parse(Base64.decode64(URI.decode_www_form_component(forwarded.body.delete_prefix("data="))))
    assert_equal [ "GB", true ], sent["properties"].values_at("$geoip_country_code", "internal")
    assert_equal "application/x-www-form-urlencoded", forwarded.headers["Content-Type"]
  end

  test "a chunked upload with no length is still capped at 1 MB" do
    post "/relay/e/", params: "x" * (RelayController::MAX_BODY + 10),
      headers: { "Content-Type" => "text/plain", "Transfer-Encoding" => "chunked" }, env: { "CONTENT_LENGTH" => nil }

    assert_response :content_too_large
    assert_not_requested :any, /posthog\.com/
  end

  test "properties that aren't an object are replaced, not a 500" do
    forwarded = nil
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).with { |request| forwarded = request }.to_return(status: 200, body: "{}")

    send_events({ event: "x", properties: "bad" })

    assert_response :success
    assert_equal "GB", forwarded_events(forwarded).sole["properties"]["$geoip_country_code"]
  end

  test "a stalled upload to PostHog is a 502 too" do
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).to_raise(Net::WriteTimeout)

    send_events({ event: "$pageview" })

    assert_response :bad_gateway
  end

  test "a body that isn't JSON is passed on as it is" do
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).with(body: "data=abc").to_return(status: 200, body: "{}")

    send_events("data=abc")

    assert_response :success
  end

  test "PostHog not answering is a 502, after the timeout" do
    stub_request(:post, %r{\Ahttps://us\.i\.posthog\.com/e/}).to_timeout

    send_events({ event: "$pageview" })

    assert_response :bad_gateway
  end

  test "120 requests a minute per visitor" do
    stub_request(:get, "https://us-assets.i.posthog.com/static/array.js").to_return(status: 200, body: "")

    RelayController::RATE_LIMIT.times { get "/relay/static/array.js", env: { "REMOTE_ADDR" => VISITOR } }
    assert_response :success
    get "/relay/static/array.js", env: { "REMOTE_ADDR" => VISITOR }
    assert_response :too_many_requests
    get "/relay/static/array.js", env: { "REMOTE_ADDR" => "8.8.8.8" }
    assert_response :success, "another visitor isn't held back"
  end
end
