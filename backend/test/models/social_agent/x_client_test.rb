require "test_helper"

# Posting to X (#769, part 2): OAuth 1.0a with four static values, one write per post, no reads, never retried.
# Dummy keys; no network.
class SocialAgent::XClientTest < ActiveSupport::TestCase
  KEYS = { "X_API_KEY" => "ck", "X_API_SECRET" => "cs", "X_ACCESS_TOKEN" => "at", "X_ACCESS_TOKEN_SECRET" => "as" }.freeze

  setup do
    @saved = ENV.to_h.slice(*KEYS.keys)
    ENV.update(KEYS)
    @sent = []
  end

  teardown { KEYS.each_key { |key| @saved.key?(key) ? ENV[key] = @saved[key] : ENV.delete(key) } }

  def client(reply) = SocialAgent::XClient.new(http: ->(request) { @sent << request; reply.respond_to?(:call) ? reply.call : reply },
    clock: -> { 1_700_000_000 }, nonce: -> { "abc" })

  test "a post is one signed write with the text and its link; the permalink needs no read" do
    sent = client({ "data" => { "id" => "123" } }).call("Acme Fission won a DOE award.", "https://nuclear-directory.org/companies/acme")
    assert_equal({ id: "123", permalink: "https://x.com/i/web/status/123" }, sent)
    request = @sent.sole
    assert_equal [ "POST", "https://api.x.com/2/tweets" ], [ request.method, request.uri.to_s ]
    assert_equal "Acme Fission won a DOE award.\n\nhttps://nuclear-directory.org/companies/acme", JSON.parse(request.body)["text"]

    header = request["Authorization"]
    assert_match(/\AOAuth oauth_consumer_key="ck", oauth_nonce="abc", oauth_signature="[^"]+", oauth_signature_method="HMAC-SHA1", oauth_timestamp="1700000000", oauth_token="at", oauth_version="1.0"\z/, header)
    base = "POST&https%3A%2F%2Fapi.x.com%2F2%2Ftweets&" + ERB::Util.url_encode("oauth_consumer_key=ck&oauth_nonce=abc&oauth_signature_method=HMAC-SHA1&oauth_timestamp=1700000000&oauth_token=at&oauth_version=1.0")
    expected = Base64.strict_encode64(OpenSSL::HMAC.digest("sha1", "cs&as", base))
    assert_equal expected, CGI.unescape(header[/oauth_signature="([^"]+)"/, 1])
  end

  test "no id back is 'may have gone out'; missing keys say what to set" do
    assert_raises(SocialAgent::Uncertain) { client({}).call("Text.", "https://nuclear-directory.org/") }
    ENV.delete("X_ACCESS_TOKEN")
    error = assert_raises(SocialAgent::XClient::Error) { client({}).call("Text.", "https://nuclear-directory.org/") }
    assert_match "X_ACCESS_TOKEN", error.message
  end
end
