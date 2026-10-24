require "net/http"
require "ipaddr"

# The polite HTTP client every plug-in fetches through:
# - identifies itself honestly (USER_AGENT); never pretends to be a browser
# - checks robots.txt before every URL, including redirect targets
# - waits between requests to the same host
# - sends ETag / Last-Modified back, so unchanged pages cost a 304
# - never retries: a block (401/403) is reported, not worked around
# - stops reading after max_bytes, so a huge file costs neither side much
# - fetches public https URLs only (SSRF): the standard port, redirects that
#   stay on the same host (www. or not), and hosts whose addresses are all
#   public; it connects to the address it checked, so DNS can't swap in an
#   internal one between the check and the request
#
#   response = DataQuality::Fetcher.new.get(url, etag: source.etag)
#   response.kind # => :ok, :not_modified, :blocked, :disallowed or :error
class DataQuality::Fetcher
  # Who to write to about a visit, in the user agent of every request and on
  # /bot. SEC's fair-access policy asks for one (#129).
  CONTACT_EMAIL = "bot@mail.nuclear-directory.org"
  USER_AGENT = "NuclearDirectoryBot/0.1 (+https://nuclear-directory.org/bot; #{CONTACT_EMAIL})".freeze
  AGENT_TOKEN = "NuclearDirectoryBot"
  HOST_INTERVAL = 3 # seconds between requests to one host
  MAX_REDIRECTS = 3
  MAX_BYTES = 20.megabytes
  NETWORK_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH, SocketError, EOFError, OpenSSL::SSL::SSLError ].freeze
  # IPv4 that isn't the public internet, besides IPAddr's private, loopback
  # and link-local (169.254.0.0/16 holds cloud metadata services).
  NON_PUBLIC_V4 = %w[0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
    224.0.0.0/4 240.0.0.0/4].map { IPAddr.new(_1) }.freeze
  # IPv6 is public only inside global unicast (2000::/3), minus its
  # special-use blocks: IETF protocol assignments (incl. Teredo), 6to4 (which
  # can wrap any IPv4 address) and the documentation prefixes. Everything
  # else (local, NAT64, reserved, site-local, multicast) is refused.
  GLOBAL_V6 = IPAddr.new("2000::/3")
  NON_PUBLIC_V6 = %w[2001::/23 2001:db8::/32 2002::/16 3fff::/20].map { IPAddr.new(_1) }.freeze

  # A URL the fetcher won't request (not https, another host, an internal address).
  class Refused < StandardError; end

  # Resolves a host to its IP addresses. Tests replace it so they never use DNS.
  class << self
    attr_writer :resolver

    def resolver = @resolver ||= ->(host) { Addrinfo.getaddrinfo(host, 443, nil, :STREAM).map(&:ip_address).uniq }
  end

  # kind:            :ok, :not_modified, :blocked, :disallowed or :error
  # reason:          why, in words, for anything but :ok / :not_modified
  # block_reference: the CDN's reference id on a block page (e.g. Akamai's
  #                  "Reference #18.…"), for asking the site owner about it
  # content_type:    e.g. "text/html"
  # truncated:       true when the body was cut off at max_bytes
  Response = Data.define(:url, :kind, :status, :body, :etag, :last_modified, :reason, :block_reference,
    :content_type, :truncated)

  # A raw HTTP response and as much of its body as was read.
  Fetched = Data.define(:http, :body, :truncated)
  class BodyLimitReached < StandardError; end

  def initialize(sleeper: ->(seconds) { sleep seconds }, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
    open_timeout: 10, read_timeout: 60, resolver: DataQuality::Fetcher.resolver)
    @resolver = resolver
    @sleeper = sleeper
    @clock = clock
    @open_timeout = open_timeout
    @read_timeout = read_timeout
    @robots = {}
    @last_request_at = {}
  end

  # binary: true returns the body as raw bytes (e.g. a spreadsheet) instead
  # of converting it to UTF-8 text.
  # Every fetch is https, on its starting host (www. or not) and on public
  # addresses (see check_url! and public_address!).
  def get(url, etag: nil, last_modified: nil, max_bytes: MAX_BYTES, binary: false)
    redirects = 0
    first_host = nil

    loop do
      uri = URI.parse(url)
      check_url!(uri, first_host:)
      first_host ||= uri.host
      verdict = robots_verdict(uri)
      return verdict if verdict

      headers = { "If-None-Match" => etag, "If-Modified-Since" => last_modified }.compact
      fetched = request(uri, headers, max_bytes:)
      http = fetched.http

      if http.is_a?(Net::HTTPRedirection) && http["Location"] && redirects < MAX_REDIRECTS
        redirects += 1
        url = URI.join(url, http["Location"]).to_s
        next
      end

      return classify(url, fetched, binary:)
    end
  rescue Refused, URI::InvalidURIError => error
    response(url, :error, reason: "Not fetched: #{error.message}")
  rescue *NETWORK_ERRORS => error
    response(url, :error, reason: "Network error: #{error.class}: #{error.message}")
  end

  # A search an API only takes as a POST with a JSON body (USAspending's,
  # #123), by the same rules as get: https on a public host, robots.txt,
  # spacing between requests, the body limit, an honest user agent, no
  # retries. A redirect isn't followed (an API that redirects a POST is
  # reported as an error); there are no ETags.
  def post_json(url, payload, max_bytes: MAX_BYTES)
    uri = URI.parse(url)
    check_url!(uri, first_host: nil)
    verdict = robots_verdict(uri)
    return verdict if verdict

    fetched = request(uri, { "Content-Type" => "application/json", "Accept" => "application/json" }, max_bytes:, post_body: payload.to_json)
    if fetched.http.is_a?(Net::HTTPRedirection)
      return response(url, :error, status: fetched.http.code.to_i, reason: "HTTP #{fetched.http.code}: a redirect after a POST isn't followed")
    end

    classify(url, fetched)
  rescue Refused, URI::InvalidURIError => error
    response(url, :error, reason: "Not fetched: #{error.message}")
  rescue *NETWORK_ERRORS => error
    response(url, :error, reason: "Network error: #{error.class}: #{error.message}")
  end

  private
    # Public https on the standard port, and (after a redirect) the same host.
    def check_url!(uri, first_host:)
      raise Refused, "only https URLs are fetched" unless uri.is_a?(URI::HTTPS) && uri.host.present?
      raise Refused, "only the standard https port is fetched" unless uri.port == 443
      return if first_host.nil? || same_site?(uri.host, first_host)

      raise Refused, "redirected to another host (#{uri.host}), which isn't followed"
    end

    def same_site?(host, other) = host.downcase.delete_prefix("www.") == other.downcase.delete_prefix("www.")

    # The host's address, if every address it resolves to is public.
    def public_address!(host)
      addresses = @resolver.call(host)
      raise Refused, "#{host} doesn't resolve" if addresses.empty?

      internal = addresses.find { |address| !public_ip?(address) }
      raise Refused, "#{host} resolves to an internal address (#{internal})" if internal

      addresses.first
    end

    def public_ip?(address)
      ip = IPAddr.new(address).native # an IPv4-mapped IPv6 address is checked as IPv4
      if ip.ipv4?
        !(ip.private? || ip.loopback? || ip.link_local? || NON_PUBLIC_V4.any? { |range| range.include?(ip) })
      else
        GLOBAL_V6.include?(ip) && NON_PUBLIC_V6.none? { |range| range.include?(ip) }
      end
    rescue IPAddr::InvalidAddressError
      false
    end

    # nil when robots.txt allows the URL, else the Response to return.
    def robots_verdict(uri)
      origin = [ uri.scheme, uri.host, uri.port ]
      robots = @robots[origin] ||= fetch_robots(uri)
      return robots if robots.is_a?(Response)
      return if robots.allowed?(uri.to_s, agent: AGENT_TOKEN)

      response(uri.to_s, :disallowed, reason: "robots.txt disallows #{uri.path} for #{AGENT_TOKEN}")
    end

    # A DataQuality::Robots, or a Response when robots.txt itself can't be read.
    # Per RFC 9309: missing (4xx) means everything is allowed; unreachable
    # (5xx, network) means nothing is. A 401/403 is a block, not "missing".
    def fetch_robots(uri)
      robots_uri = uri.dup.tap { |copy| copy.path = "/robots.txt"; copy.query = copy.fragment = nil }
      fetched = request(robots_uri, {}, max_bytes: 1.megabyte)
      status = fetched.http.code.to_i

      case status
      when 200..299 then DataQuality::Robots.parse(body_of(fetched))
      when 401, 403 then classify(robots_uri.to_s, fetched)
      when 400..499 then DataQuality::Robots.parse("")
      else response(robots_uri.to_s, :error, status:, reason: "robots.txt returned #{status}; not crawling #{uri.host}")
      end
    rescue *NETWORK_ERRORS => error
      response(robots_uri.to_s, :error, reason: "robots.txt unreachable (#{error.class}); not crawling #{uri.host}")
    end

    # Reads the body in chunks and hangs up once it has more than max_bytes.
    # A body of exactly max_bytes is complete; only going past it means
    # there was more.
    # post_body: the body of a POST; without one, a GET.
    def request(uri, headers, max_bytes:, post_body: nil)
      wait_for(uri.host)
      get = post_body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      get.body = post_body if post_body
      get["User-Agent"] = USER_AGENT
      headers.each { |name, value| get[name] = value }

      response = nil
      body = +""
      connection(uri).start do |http|
        http.request(get) do |res|
          response = res
          res.read_body do |chunk|
            body << chunk
            raise BodyLimitReached if body.bytesize > max_bytes
          end
        end
      end
      Fetched.new(http: response, body: body, truncated: false)
    rescue BodyLimitReached
      Fetched.new(http: response, body: body.byteslice(0, max_bytes), truncated: true)
    end

    # Connects to the address public_address! checked; TLS (SNI, the
    # certificate) and the Host header still use the name. Never through a
    # proxy (Net::HTTP would read http_proxy from the environment), which
    # would resolve the name itself.
    def connection(uri)
      Net::HTTP.new(uri.host, uri.port, nil).tap do |http|
        http.ipaddr = public_address!(uri.host)
        http.use_ssl = true
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout
      end
    end

    def wait_for(host)
      if (last = @last_request_at[host])
        remaining = HOST_INTERVAL - (@clock.call - last)
        @sleeper.call(remaining) if remaining.positive?
      end
      @last_request_at[host] = @clock.call
    end

    def classify(url, fetched, binary: false)
      http = fetched.http
      status = http.code.to_i
      # A bot challenge is a block whatever its status (200 or 503 with
      # Cloudflare's marker): recorded, never worked around (#510).
      if http["cf-mitigated"].to_s.casecmp?("challenge")
        return response(url, :blocked, status:, reason: "Bot challenge (HTTP #{status}) from #{http['Server'] || 'the server'}")
      end

      case status
      when 200..299
        body = binary ? fetched.body.b : body_of(fetched)
        response(url, :ok, status:, body:, etag: http["ETag"], last_modified: http["Last-Modified"],
          content_type: http.content_type, truncated: fetched.truncated)
      when 304
        response(url, :not_modified, status:, etag: http["ETag"], last_modified: http["Last-Modified"])
      when 401, 403
        reference = block_reference(fetched)
        response(url, :blocked, status:, block_reference: reference,
          reason: [ "HTTP #{status} from #{http['Server'] || 'the server'}", reference && "reference ##{reference}" ].compact.join(", "))
      else
        response(url, :error, status:, reason: "HTTP #{status}")
      end
    end

    def response(url, kind, status: nil, body: nil, etag: nil, last_modified: nil, reason: nil, block_reference: nil,
      content_type: nil, truncated: false)
      Response.new(url:, kind:, status:, body:, etag:, last_modified:, reason:, block_reference:, content_type:, truncated:)
    end

    def body_of(fetched)
      body = fetched.body.dup
      charset = fetched.http.type_params["charset"]
      body.force_encoding(Encoding.find(charset)) rescue body.force_encoding(Encoding::UTF_8)
      body.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end

    # Akamai puts the id in a header and in the page ("Reference&#32;&#35;18&#46;…").
    def block_reference(fetched)
      fetched.http["X-Reference-Error"].presence ||
        CGI.unescapeHTML(body_of(fetched))[/Reference\s*#\s*([\w.]+)/, 1]
    end
end
