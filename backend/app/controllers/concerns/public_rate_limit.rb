# A per-IP limit on the public pages (#859): on 20 Nov one crawler asked for
# company pages back to back while each took seconds in the database. People
# and search engines never reach the limit; the rest get a 429 with
# Retry-After, and each limited request is logged.
#
# Not limited: the admin and the API (their own limits), a signed-in admin,
# and a search engine's crawler verified by its IP's reverse and forward DNS
# (a user agent alone is easy to fake). /up isn't an ApplicationController.
# The counts live in this process's memory, not the database: counting must
# not add a write to every page.
module PublicRateLimit
  extend ActiveSupport::Concern

  LIMIT = 40
  WINDOW = 1.minute
  STORE = ActiveSupport::Cache::MemoryStore.new(size: 8.megabytes)
  # Search engines' crawlers and the domains their IPs resolve to.
  SEARCH_BOTS = {
    /Googlebot|Google-InspectionTool|GoogleOther/i => %w[googlebot.com google.com],
    /bingbot|BingPreview/i => %w[search.msn.com],
    /DuckDuckBot/i => %w[duckduckgo.com],
    /Applebot/i => %w[applebot.apple.com],
    /YandexBot/i => %w[yandex.com yandex.net yandex.ru]
  }.freeze
  VERIFIED = ActiveSupport::Cache::MemoryStore.new(size: 1.megabyte)
  # Link-preview bots (a post's card), our own monitors and fetcher: their
  # IPs are many or shared, so each family gets one generous count of its own
  # instead of a per-IP one; a scraper faking one can't pass FRIENDLY_LIMIT.
  FRIENDLY = {
    "linkedin" => /LinkedInBot/i, "x" => /Twitterbot/i, "facebook" => /facebookexternalhit|Facebot|meta-externalagent/i,
    "buffer" => /Buffer/i, "slack" => /Slackbot|Slack-ImgProxy/i, "discord" => /Discordbot/i, "telegram" => /TelegramBot/i,
    "whatsapp" => /WhatsApp/i, "bluesky" => /Bluesky|cardyb/i, "uptimerobot" => /UptimeRobot/i, "nd-uptime" => %r{\And-uptime/},
    "nd-bot" => /NuclearDirectoryBot/
  }.freeze
  FRIENDLY_LIMIT = 300
  DNS_TIMEOUT = 2
  # New lookups a minute, process-wide: a faker rotating IPs can't tie up the threads (Infra).
  LOOKUPS_PER_MINUTE = 20
  # Off in tests, where every page test shares one IP; its own test turns it on.
  mattr_accessor :enabled, default: !Rails.env.test?
  mattr_accessor :resolver, default: -> { Resolv::DNS.new }

  included do
    rate_limit to: LIMIT, within: WINDOW, store: STORE, name: "public", scope: "public", by: -> { request.remote_ip },
      with: -> { limited! }, unless: -> { rate_limit_exempt? || friendly_bot }
    rate_limit to: FRIENDLY_LIMIT, within: WINDOW, store: STORE, name: "friendly", scope: "public", by: -> { friendly_bot },
      with: -> { limited! }, if: -> { !rate_limit_exempt? && friendly_bot }
  end

  # Reverse DNS to the engine's domain, and that name forward to the same IP; kept a day per IP.
  def self.verified_search_bot?(ip, user_agent)
    domains = SEARCH_BOTS.find { |pattern, _| user_agent.to_s.match?(pattern) }&.last or return false

    key = "#{ip}:#{domains.first}"
    cached = VERIFIED.read(key)
    return cached unless cached.nil?
    return false if VERIFIED.increment("lookups:#{Time.current.to_i / 60}", 1, expires_in: 2.minutes).to_i > LOOKUPS_PER_MINUTE

    VERIFIED.fetch(key, expires_in: 1.day) do
      Timeout.timeout(DNS_TIMEOUT) do
        dns = resolver.call
        name = dns.getname(ip).to_s.downcase
        domains.any? { |domain| name == domain || name.end_with?(".#{domain}") } &&
          dns.getaddresses(name).any? { |address| IPAddr.new(address.to_s) == IPAddr.new(ip) }
      end
    rescue Resolv::ResolvError, Timeout::Error, ArgumentError, IPAddr::Error
      false
    end
  end

  private
    def rate_limit_exempt?
      !PublicRateLimit.enabled || self.class.name.start_with?("Admin::", "Api::") || live_admin_session? ||
        PublicRateLimit.verified_search_bot?(request.remote_ip, request.user_agent)
    end

    def friendly_bot = FRIENDLY.find { |_, pattern| request.user_agent.to_s.match?(pattern) }&.first

    def limited!
      Rails.logger.warn("[rate-limit] #{request.remote_ip} #{request.method} #{request.path} ua=#{request.user_agent.to_s.truncate(120).inspect}")
      response.set_header("Retry-After", WINDOW.to_i.to_s)
      head :too_many_requests
    end
end
