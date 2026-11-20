require "test_helper"

class PublicRateLimitTest < ActionDispatch::IntegrationTest
  setup do
    PublicRateLimit.enabled = true
    PublicRateLimit::STORE.clear
    PublicRateLimit::VERIFIED.clear
  end

  teardown { PublicRateLimit.enabled = false }

  def hit(times, **headers) = times.times.map { get "/about", headers:; response.status }.last

  test "an anonymous client past the limit gets a 429 with Retry-After, and it's logged" do
    assert_equal 200, hit(PublicRateLimit::LIMIT)
    logged = capture_log { get "/about" }
    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_match "[rate-limit] 127.0.0.1 GET /about", logged
  end

  test "another IP has its own count" do
    hit(PublicRateLimit::LIMIT + 1)
    get "/about", headers: { "REMOTE_ADDR" => "10.0.0.9" }
    assert_response :ok
  end

  FakeDNS = Struct.new(:names, :addresses) do
    def getname(ip) = names.fetch(ip) { raise Resolv::ResolvError }
    def getaddresses(name) = addresses.fetch(name, [])
  end

  def with_dns(names, addresses)
    PublicRateLimit.resolver = -> { FakeDNS.new(names, addresses) }
    yield
  ensure
    PublicRateLimit.resolver = -> { Resolv::DNS.new }
  end

  test "a verified search engine crawler isn't limited; one only claiming to be is" do
    googlebot = { "User-Agent" => "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)" }
    with_dns({ "127.0.0.1" => "crawl-127-0-0-1.googlebot.com" }, { "crawl-127-0-0-1.googlebot.com" => [ "127.0.0.1" ] }) do
      assert_equal 200, hit(PublicRateLimit::LIMIT + 5, **googlebot)
    end
    PublicRateLimit::VERIFIED.clear
    with_dns({ "127.0.0.1" => "host.example.net" }, {}) do
      assert_equal 429, hit(PublicRateLimit::LIMIT + 1, **googlebot)
    end
  end

  test "verification needs the reverse name on the engine's domain and the forward lookup back to the IP" do
    with_dns({ "66.249.66.1" => "crawl-66-249-66-1.googlebot.com", "1.2.3.4" => "spoof.googlebot.com.evil.net", "5.6.7.8" => "x.googlebot.com" },
      { "crawl-66-249-66-1.googlebot.com" => [ "66.249.66.1" ], "x.googlebot.com" => [ "9.9.9.9" ] }) do
      assert PublicRateLimit.verified_search_bot?("66.249.66.1", "Googlebot/2.1")
      refute PublicRateLimit.verified_search_bot?("1.2.3.4", "Googlebot/2.1"), "not the engine's domain"
      refute PublicRateLimit.verified_search_bot?("5.6.7.8", "Googlebot/2.1"), "forward lookup isn't the IP"
      refute PublicRateLimit.verified_search_bot?("66.249.66.1", "SomeScraper/1.0"), "not a search engine"
    end
  end

  private
    def capture_log
      io = StringIO.new
      logger, Rails.logger = Rails.logger, ActiveSupport::Logger.new(io)
      yield
      io.string
    ensure
      Rails.logger = logger
    end
end
