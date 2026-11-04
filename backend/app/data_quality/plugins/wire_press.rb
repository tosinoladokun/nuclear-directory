# Company press releases as the newswire carries them (PM, 3 Nov): a way to
# read the news of companies whose own sites refuse our bot (Duke, TVA,
# NextEra, Equinix, Oracle), honestly. PR Newswire's own energy and utilities
# RSS feeds, which its robots.txt allows. (GlobeNewswire refuses our bot;
# Business Wire's robots.txt disallows /rss/ for general bots: neither is read.)
#
# A category feed holds only its 20 newest items, so it's read every
# READ_HOURS (the recurring job in config/recurring.yml) and its items are
# kept, newest WINDOW_DAYS, in the stored copy: each read adds what's new. A
# block is recorded and the feed skipped, as everywhere.
#
# Extract: an item becomes a news item claim only when it names a company or
# plant in the directory (as trade press reads names) and is about nuclear
# work (the newsrooms' NUCLEAR words). The release is the named company's
# own announcement, distributed by PR Newswire; never a lead. At most
# PER_FEED a read.
class DataQuality::Plugins::WirePress < DataQuality::Plugins::TradePress
  FEEDS = {
    "PR Newswire (energy)" => "https://www.prnewswire.com/rss/energy-latest-news/energy-latest-news-list.rss",
    "PR Newswire (utilities)" => "https://www.prnewswire.com/rss/energy-latest-news/utilities-list.rss"
  }.freeze
  PUBLISHER = "PR Newswire"
  WINDOW_DAYS = 14
  READ_HOURS = 3
  PER_FEED = 15

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new, now: -> { Time.current })
    super(fetcher:, feeds:, today:, directory:)
    @now = now
  end

  def crawl(_run)
    @feeds.each_with_object({}) do |(name, url), stats|
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = "#{name}: news releases"
      end
      stats[name] = DataQuality::Snapshot.claim(source) { read(source) }.to_s
    end
  end

  def extract(source, _run)
    since = @today.call - WINDOW_DAYS
    taken = decided_urls(source)
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }
      .select { |item| "#{item.title} #{item.summary}".match?(NUCLEAR) }
      .sort_by(&:published_on).reverse.filter_map do |item|
        named = named_in("#{item.title} #{item.summary}")
        next if named.empty?

        { kind: "news_item", quote: item.title, payload: {
          "url" => item.url, "title" => item.title, "publisher" => PUBLISHER, "published_on" => item.published_on.iso8601,
          "summary" => item.summary, "about" => named }.compact }
      end.first(PER_FEED)
  end

  def source_facts(_source)
    "This is PR Newswire's feed of news releases: each item is a release a company issued through PR Newswire, with " \
      "its title, date, link and the release's opening words."
  end

  private
    # Every READ_HOURS: the feed's items merged into those kept, newest WINDOW_DAYS, stored as RSS.
    def read(source)
      return :skipped_recent if source.fetched_at && source.fetched_at > @now.call - READ_HOURS.hours

      response = @fetcher.get(source.url)
      attempt = { fetched_at: @now.call, http_status: response.status }
      unless response.kind == :ok
        streak = response.kind == :blocked ? source.blocked_streak + 1 : source.blocked_streak
        status = response.kind == :disallowed || streak >= DataQuality::Snapshot::BLOCKED_STREAK_LIMIT ? "needs_human" : (response.kind == :blocked ? "blocked" : source.crawl_status)
        source.update!(attempt.merge(status_reason: response.reason, blocked_streak: streak, crawl_status: status))
        return response.kind
      end

      fresh = items(response.body) or (source.update!(attempt.merge(crawl_status: "needs_human", status_reason: NOT_A_FEED)) && (return :needs_human))
      since = @today.call - WINDOW_DAYS
      kept = (fresh + Array(items(source.content_text))).uniq(&:url).select { |item| item.published_on && item.published_on >= since }
        .sort_by(&:published_on).reverse
      text = rss(kept)
      sha = Digest::SHA256.hexdigest(text)
      changed = sha != source.content_sha256
      source.update!(attempt.merge(crawl_status: "ok", status_reason: nil, blocked_streak: 0).merge(changed ? { content_text: text, content_sha256: sha } : {}))
      changed ? :changed : :unchanged
    end

    def rss(items)
      Nokogiri::XML::Builder.new(encoding: "UTF-8") do |xml|
        xml.rss(version: "2.0") do
          xml.channel do
            xml.title PUBLISHER
            items.each do |item|
              xml.item do
                xml.title item.title
                xml.link item.url
                xml.pubDate item.published_on.httpdate
                xml.description item.summary if item.summary
              end
            end
          end
        end
      end.to_xml
    end
end
