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
  DNS_TIMEOUT = 2
  # Off in tests, where every page test shares one IP; its own test turns it on.
  mattr_accessor :enabled, default: !Rails.env.test?
  mattr_accessor :resolver, default: -> { Resolv::DNS.new }

  included do
    rate_limit to: LIMIT, within: WINDOW, store: STORE, name: "public", by: -> { request.remote_ip },
      with: -> { limited! }, unless: :rate_limit_exempt?
  end

  # Reverse DNS to the engine's domain, and that name forward to the same IP; kept a day per IP.
  def self.verified_search_bot?(ip, user_agent)
    domains = SEARCH_BOTS.find { |pattern, _| user_agent.to_s.match?(pattern) }&.last or return false

    VERIFIED.fetch("#{ip}:#{domains.first}", expires_in: 1.day) do
      Timeout.timeout(DNS_TIMEOUT) do
        dns = resolver.call
        name = dns.getname(ip).to_s.downcase
        domains.any? { |domain| name == domain || name.end_with?(".#{domain}") } &&
          dns.getaddresses(name).map(&:to_s).include?(ip)
      end
    rescue Resolv::ResolvError, Timeout::Error, ArgumentError
      false
    end
  end

  private
    def rate_limit_exempt?
      !PublicRateLimit.enabled || self.class.name.start_with?("Admin::", "Api::") || cookies.signed[:session_id].present? ||
        PublicRateLimit.verified_search_bot?(request.remote_ip, request.user_agent)
    end

    def limited!
      Rails.logger.warn("[rate-limit] #{request.remote_ip} #{request.method} #{request.path} ua=#{request.user_agent.to_s.truncate(120).inspect}")
      response.set_header("Retry-After", WINDOW.to_i.to_s)
      head :too_many_requests
    end
end
