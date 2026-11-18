require "net/http"

# Posts to X as @NuclearDir (#769, part 2): OAuth 1.0a user context with the app's four static values, which
# don't expire (Infra: no tokens to refresh or store). Pay-per-use: one write per post and no reads at all.
#
# Set up (Tosin, signed in to X as the brand account): an app at console.x.com with read and write permission;
# its API Key and Secret and the account's Access Token and Secret in Render as X_API_KEY, X_API_SECRET,
# X_ACCESS_TOKEN and X_ACCESS_TOKEN_SECRET (dashboard only).
class SocialAgent::XClient
  TWEETS = URI("https://api.x.com/2/tweets")
  KEYS = %w[X_API_KEY X_API_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET].freeze

  class Error < StandardError; end

  def self.configured? = KEYS.all? { |key| ENV[key].present? }

  def initialize(http: method(:deliver), clock: -> { Time.now.to_i }, nonce: -> { SecureRandom.hex(16) })
    @http = http
    @clock = clock
    @nonce = nonce
  end

  # One post: the text, a blank line, the link. Returns { id:, permalink: }. Never retried: a timeout, a server
  # error or a rate limit may mean it went out, so it's SocialAgent::Uncertain.
  def call(text, link)
    raise Error, "X isn't set up: #{KEYS.join(', ')} on Render" unless self.class.configured?

    request = Net::HTTP::Post.new(TWEETS, "Content-Type" => "application/json")
    request.body = { text: "#{text}\n\n#{link}" }.to_json
    request["Authorization"] = authorization("POST", TWEETS.to_s)
    id = @http.call(request).dig("data", "id") or raise SocialAgent::Uncertain, "X didn't return the post's id"
    { id:, permalink: "https://x.com/i/web/status/#{id}" }
  end

  # OAuth 1.0a (HMAC-SHA1). A JSON body isn't part of the signature, so only the oauth_ values are signed.
  def authorization(method, url)
    params = { oauth_consumer_key: ENV.fetch("X_API_KEY"), oauth_nonce: @nonce.call, oauth_signature_method: "HMAC-SHA1",
               oauth_timestamp: @clock.call.to_s, oauth_token: ENV.fetch("X_ACCESS_TOKEN"), oauth_version: "1.0" }
    base = [ method, escape(url), escape(params.sort.map { |key, value| "#{escape(key)}=#{escape(value)}" }.join("&")) ].join("&")
    key = "#{escape(ENV.fetch('X_API_SECRET'))}&#{escape(ENV.fetch('X_ACCESS_TOKEN_SECRET'))}"
    params[:oauth_signature] = Base64.strict_encode64(OpenSSL::HMAC.digest("sha1", key, base))
    "OAuth " + params.sort.map { |key_name, value| %(#{escape(key_name)}="#{escape(value)}") }.join(", ")
  end

  private
    def escape(value) = ERB::Util.url_encode(value.to_s)

    def deliver(request)
      response = Net::HTTP.start(TWEETS.host, TWEETS.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
      code = response.code.to_i
      # Only a clear refusal (4xx other than 429) means it didn't go out; anything else may have.
      raise Error, "X said #{code}: #{response.body.to_s.truncate(200)}" if code.between?(400, 499) && code != 429
      raise SocialAgent::Uncertain, "X said #{code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise SocialAgent::Uncertain, "X's reply wasn't readable"
    rescue Net::OpenTimeout => error
      raise Error, "couldn't reach X (#{error.class}), nothing sent"
    rescue Net::ReadTimeout, EOFError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => error
      raise SocialAgent::Uncertain, error.class.name
    end
end
