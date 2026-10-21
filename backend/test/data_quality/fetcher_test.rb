require "test_helper"

class DataQuality::FetcherTest < ActiveSupport::TestCase
  def with_env(vars)
    saved = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| ENV[key] = value }
  end

  PAGE = "https://example.gov/reactors"
  ROBOTS = "https://example.gov/robots.txt"

  setup do
    @sleeps = []
    @now = 0.0
    @fetcher = DataQuality::Fetcher.new(sleeper: ->(s) { @sleeps << s; @now += s }, clock: -> { @now })
    stub_request(:get, ROBOTS).to_return(body: "User-agent: *\nDisallow: /private/\n")
  end

  test "identifies itself honestly and returns the page with its validators" do
    stub = stub_request(:get, PAGE)
      .with(headers: { "User-Agent" => "NuclearDirectoryBot/0.1 (+https://nuclear-directory.org/bot; bot@mail.nuclear-directory.org)" })
      .to_return(body: "<p>hi</p>", headers: { "ETag" => '"v1"', "Last-Modified" => "Fri, 09 Oct 2026 20:40:21 GMT",
        "Content-Type" => "text/html; charset=utf-8" })

    response = @fetcher.get(PAGE)

    assert_requested stub
    assert_equal [ :ok, 200, "<p>hi</p>", '"v1"' ], [ response.kind, response.status, response.body, response.etag ]
    assert_equal Encoding::UTF_8, response.body.encoding
    assert_equal [ "text/html", false ], [ response.content_type, response.truncated ]
  end

  test "stops reading at max_bytes and says so" do
    stub_request(:get, PAGE).to_return(body: "a" * 5_000)

    response = @fetcher.get(PAGE, max_bytes: 1_000)

    assert_equal :ok, response.kind
    assert response.truncated
    assert_equal 1_000, response.body.bytesize
  end

  test "a body of exactly max_bytes is complete, not truncated" do
    stub_request(:get, PAGE).to_return(body: "a" * 1_000)

    response = @fetcher.get(PAGE, max_bytes: 1_000)

    assert_not response.truncated
    assert_equal 1_000, response.body.bytesize
  end

  test "asks whether the page changed and understands 304" do
    stub = stub_request(:get, PAGE)
      .with(headers: { "If-None-Match" => '"v1"', "If-Modified-Since" => "Fri, 09 Oct 2026 20:40:21 GMT" })
      .to_return(status: 304)

    response = @fetcher.get(PAGE, etag: '"v1"', last_modified: "Fri, 09 Oct 2026 20:40:21 GMT")

    assert_requested stub
    assert_equal :not_modified, response.kind
  end

  test "reports a block with Akamai's reference id, and doesn't retry" do
    stub_request(:get, PAGE).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read,
      headers: { "Server" => "AkamaiGHost" })

    response = @fetcher.get(PAGE)

    assert_equal :blocked, response.kind
    assert_equal "18.4460d017.1791618638.14c00ece", response.block_reference
    assert_match "HTTP 403 from AkamaiGHost, reference #18.4460d017", response.reason
    assert_requested :get, PAGE, times: 1
  end

  test "prefers the reference header when there is one" do
    stub_request(:get, PAGE).to_return(status: 403, headers: { "X-Reference-Error" => "18.abc" }, body: "Access Denied")

    assert_equal "18.abc", @fetcher.get(PAGE).block_reference
  end

  test "never fetches what robots.txt disallows" do
    response = @fetcher.get("https://example.gov/private/page")

    assert_equal :disallowed, response.kind
    assert_not_requested :get, "https://example.gov/private/page"
  end

  test "reads robots.txt once per host and waits between requests to it" do
    stub_request(:get, PAGE).to_return(body: "a")
    stub_request(:get, "#{PAGE}/2").to_return(body: "b")

    @fetcher.get(PAGE)
    @fetcher.get("#{PAGE}/2")

    assert_requested :get, ROBOTS, times: 1
    assert_equal [ DataQuality::Fetcher::HOST_INTERVAL ] * 2, @sleeps
  end

  # ---- SSRF: only public https on the source's own host

  test "only https on the standard port is fetched, as a URL or a redirect target" do
    stub_request(:get, PAGE).to_return(status: 301, headers: { "Location" => "http://example.gov/reactors" })

    [ "http://example.gov/reactors", "https://example.gov:8443/reactors", "file:///etc/passwd", "ftp://example.gov/x" ].each do |url|
      response = @fetcher.get(url)
      assert_equal :error, response.kind, url
      assert_match "Not fetched", response.reason
    end
    assert_match "only https", @fetcher.get(PAGE).reason, "a redirect to http:// isn't followed"
    assert_not_requested :get, "http://example.gov/robots.txt"
  end

  test "a redirect to another host isn't followed; www. and back is the same host" do
    stub_request(:get, PAGE).to_return(status: 302, headers: { "Location" => "https://elsewhere.example/reactors" })
    response = @fetcher.get(PAGE)
    assert_equal :error, response.kind
    assert_match "redirected to another host (elsewhere.example)", response.reason
    assert_not_requested :get, "https://elsewhere.example/robots.txt"

    stub_request(:get, "https://www.example.gov/robots.txt").to_return(status: 404)
    stub_request(:get, "https://example.gov/moved").to_return(status: 301, headers: { "Location" => "https://www.example.gov/moved" })
    stub_request(:get, "https://www.example.gov/moved").to_return(body: "here")
    assert_equal [ :ok, "here" ], @fetcher.get("https://example.gov/moved").then { |r| [ r.kind, r.body ] }
  end

  test "a host that resolves to an internal address is never requested" do
    {
      "127.0.0.1" => "loopback", "10.1.2.3" => "private", "172.16.0.1" => "private", "192.168.1.1" => "private",
      "169.254.169.254" => "cloud metadata", "100.64.0.1" => "carrier-grade NAT", "0.0.0.0" => "this host",
      "::1" => "IPv6 loopback", "fd00::1" => "IPv6 unique local", "fe80::1" => "IPv6 link-local",
      "::ffff:127.0.0.1" => "IPv4-mapped loopback", "4000::1" => "IPv6 reserved", "fec0::1" => "IPv6 site-local",
      "64:ff9b::a00:1" => "NAT64", "64:ff9b:1::1" => "local-use NAT64", "3fff::1" => "IPv6 documentation",
      "2002:a00:1::1" => "6to4 wrapping 10.0.0.1", "2001::1" => "Teredo", "ff02::1" => "IPv6 multicast",
      "192.88.99.1" => "6to4 relay anycast"
    }.each do |address, what|
      fetcher = DataQuality::Fetcher.new(sleeper: ->(_) { }, resolver: ->(_host) { [ address ] })
      response = fetcher.get("https://internal.example/x")
      assert_equal :error, response.kind, what
      assert_match "resolves to an internal address (#{address})", response.reason, what
    end
    assert_not_requested :get, %r{internal\.example}
  end

  test "public IPv6 is fetched" do
    stub_request(:get, PAGE).to_return(body: "ok")
    fetcher = DataQuality::Fetcher.new(sleeper: ->(_) { }, resolver: ->(_host) { [ "2606:4700::6810:84e5" ] })

    assert_equal :ok, fetcher.get(PAGE).kind
  end

  test "never connects through a proxy from the environment, which would resolve the name itself" do
    recording = Class.new(DataQuality::Fetcher) do
      attr_reader :proxied

      def connection(uri) = super.tap { |http| @proxied = http.proxy? }
    end
    fetcher = recording.new(sleeper: ->(_) { })
    stub_request(:get, PAGE).to_return(body: "ok")

    with_env("https_proxy" => "http://proxy.internal:3128", "http_proxy" => "http://proxy.internal:3128") do
      response = fetcher.get(PAGE)
      assert_equal :ok, response.kind, response.reason
    end
    assert_equal false, fetcher.proxied
  end

  test "a host with any internal address is refused, and a redirect's new host is checked too" do
    mixed = DataQuality::Fetcher.new(sleeper: ->(_) { }, resolver: ->(_host) { [ "93.184.215.14", "10.0.0.5" ] })
    assert_match "internal address (10.0.0.5)", mixed.get(PAGE).reason

    by_host = { "example.gov" => [ "93.184.215.14" ], "www.example.gov" => [ "169.254.169.254" ] }
    fetcher = DataQuality::Fetcher.new(sleeper: ->(_) { }, resolver: ->(host) { by_host.fetch(host) })
    stub_request(:get, PAGE).to_return(status: 301, headers: { "Location" => "https://www.example.gov/reactors" })
    assert_match "www.example.gov resolves to an internal address", fetcher.get(PAGE).reason
  end

  test "connects to the address it checked, so DNS can't change between the check and the request" do
    lookups = 0
    recording = Class.new(DataQuality::Fetcher) do
      attr_reader :connected

      def connection(uri) = super.tap { |http| (@connected ||= []) << [ http.address, http.ipaddr, http.use_ssl? ] }
    end
    fetcher = recording.new(sleeper: ->(_) { }, resolver: ->(_host) { lookups += 1; [ "93.184.215.14" ] })
    stub_request(:get, PAGE).to_return(body: "ok")

    assert_equal :ok, fetcher.get(PAGE).kind
    assert_equal [ [ "example.gov", "93.184.215.14", true ] ], fetcher.connected.uniq, "the name for TLS, the checked address to connect"
    assert_equal 2, lookups, "robots.txt and the page, each checked when connecting"
  end

  test "follows redirects, checking robots.txt for the new location" do
    stub_request(:get, PAGE).to_return(status: 301, headers: { "Location" => "/private/moved" })

    response = @fetcher.get(PAGE)

    assert_equal :disallowed, response.kind
    assert_match "/private/moved", response.reason
  end

  test "a missing robots.txt allows everything; a blocked or broken one stops the crawl" do
    stub_request(:get, ROBOTS).to_return(status: 404)
    stub_request(:get, PAGE).to_return(body: "ok")
    assert_equal :ok, @fetcher.get(PAGE).kind

    blocked = DataQuality::Fetcher.new(sleeper: ->(_) { })
    stub_request(:get, ROBOTS).to_return(status: 403, body: file_fixture("nrc/akamai-403.html").read)
    assert_equal :blocked, blocked.get(PAGE).kind

    broken = DataQuality::Fetcher.new(sleeper: ->(_) { })
    stub_request(:get, ROBOTS).to_return(status: 503)
    response = broken.get(PAGE)
    assert_equal :error, response.kind
    assert_match "not crawling", response.reason
  end

  test "server errors and timeouts are reported, not raised" do
    stub_request(:get, PAGE).to_return(status: 500).then.to_timeout

    assert_equal [ :error, 500 ], @fetcher.get(PAGE).then { |r| [ r.kind, r.status ] }
    assert_equal :error, @fetcher.get(PAGE).kind
  end

  SEARCH = "https://example.gov/api/search/"

  test "posts a JSON search honestly and returns the answer (#123)" do
    stub = stub_request(:post, SEARCH)
      .with(body: { "filters" => { "program_numbers" => [ "81.121" ] } }.to_json,
        headers: { "User-Agent" => DataQuality::Fetcher::USER_AGENT, "Content-Type" => "application/json", "Accept" => "application/json" })
      .to_return(body: '{"results":[]}', headers: { "Content-Type" => "application/json" })

    response = @fetcher.post_json(SEARCH, { filters: { program_numbers: [ "81.121" ] } })

    assert_requested stub
    assert_equal [ :ok, '{"results":[]}' ], [ response.kind, response.body ]
  end

  test "a POST obeys robots.txt and the spacing between requests to one host" do
    stub_request(:post, SEARCH).to_return(body: "{}")
    @fetcher.post_json(SEARCH, {})
    @fetcher.post_json(SEARCH, {})
    assert_equal [ DataQuality::Fetcher::HOST_INTERVAL ] * 2, @sleeps, "robots.txt, then each POST, spaced"

    response = @fetcher.post_json("https://example.gov/private/search", {})
    assert_equal :disallowed, response.kind
    assert_not_requested :post, "https://example.gov/private/search"
  end

  test "a POST that's blocked is reported, once; one that redirects isn't followed" do
    stub_request(:post, SEARCH).to_return(status: 403, headers: { "Server" => "AkamaiGHost" })
    assert_equal :blocked, @fetcher.post_json(SEARCH, {}).kind
    assert_requested :post, SEARCH, times: 1

    WebMock.reset!
    stub_request(:get, ROBOTS).to_return(body: "")
    stub_request(:post, SEARCH).to_return(status: 307, headers: { "Location" => "https://elsewhere.example/search" })
    response = @fetcher.post_json(SEARCH, {})
    assert_equal :error, response.kind
    assert_match "a redirect after a POST isn't followed", response.reason
    assert_not_requested :post, "https://elsewhere.example/search"
  end

  test "a POST goes only to a public https host" do
    assert_match "only https", @fetcher.post_json("http://example.gov/api/search/", {}).reason
    internal = DataQuality::Fetcher.new(sleeper: ->(_) { }, resolver: ->(_host) { [ "10.0.0.5" ] })
    assert_match "internal address", internal.post_json("https://internal.example/api/", {}).reason
    assert_not_requested :post, %r{internal\.example}
  end
end
