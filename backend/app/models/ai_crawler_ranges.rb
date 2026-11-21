# AI answer engines' crawlers (#864; PM, 20 Nov: being cited is the first
# goal): a request counts as one only when its IP is in the ranges the
# operator publishes for that user agent. A user agent alone is easy to fake.
# The ranges are fetched once a day (AiCrawlerRangesJob) into the cache;
# each process keeps a copy for an hour.
module AiCrawlerRanges
  LISTS = {
    /OAI-SearchBot/i => "https://openai.com/searchbot.json",
    /ChatGPT-User/i => "https://openai.com/chatgpt-user.json",
    /GPTBot/i => "https://openai.com/gptbot.json",
    /Claude(?:Bot|-User|-SearchBot)/i => "https://claude.com/crawling/bots.json",
    /Perplexity-User/i => "https://www.perplexity.com/perplexity-user.json",
    /PerplexityBot/i => "https://www.perplexity.com/perplexitybot.json"
  }.freeze
  CACHE_KEY = "ai_crawler_ranges".freeze
  KEEP = 3.days
  mattr_accessor :local, default: nil
  # Tests have no shared cache (null store).
  def self.store = (@store ||= Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache)

  # Fetches every list; a list that fails keeps its last good ranges.
  def self.refresh!(get: method(:fetch))
    ranges = (store.read(CACHE_KEY) || {}).dup
    LISTS.each_value.uniq.each do |url|
      prefixes = JSON.parse(get.call(url).to_s).fetch("prefixes", []).filter_map { |row| row["ipv4Prefix"] || row["ipv6Prefix"] }
      ranges[url] = prefixes if prefixes.any?
    rescue JSON::ParserError, KeyError, SocketError, Timeout::Error, SystemCallError, EOFError, OpenSSL::SSL::SSLError, Net::HTTPError => error
      Rails.logger.warn("[ai-crawlers] #{url}: #{error.class}")
    end
    store.write(CACHE_KEY, ranges, expires_in: KEEP)
    self.local = nil
    ranges.transform_values(&:size)
  end

  def self.verified?(ip, user_agent)
    url = LISTS.find { |pattern, _| user_agent.to_s.match?(pattern) }&.last or return false
    address = IPAddr.new(ip.to_s)
    Array(lists[url]).any? { |range| range.include?(address) }
  rescue IPAddr::Error
    false
  end

  # Read once into a local, replaced only when the new copy is ready, so a
  # thread never sees it half-cleared (Copilot). Parsed once per hourly copy (Infra).
  def self.lists
    copy = local
    return copy[:ranges] if copy && copy[:at] > 1.hour.ago

    saved = store.read(CACHE_KEY)
    # The page cache may drop it after a day (Solid Cache max_age): fetch again, at most once an hour here (Copilot).
    AiCrawlerRangesJob.perform_later if saved.nil? && !Rails.env.test?
    ranges = (saved || {}).transform_values { |prefixes| prefixes.filter_map { |p| IPAddr.new(p) rescue nil } }
    self.local = { at: Time.current, ranges: }
    ranges
  end

  def self.fetch(url)
    uri = URI(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) do |http|
      response = http.get(uri.request_uri, "User-Agent" => DataQuality::Fetcher::USER_AGENT, "Accept" => "application/json")
      response.is_a?(Net::HTTPSuccess) ? response.body : nil
    end
  end
end
