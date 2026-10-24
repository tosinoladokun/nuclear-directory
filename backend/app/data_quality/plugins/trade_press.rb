# Trade press (#127): World Nuclear News and ANS Nuclear Newswire, read as
# leads only. A trade paper reports someone else's news, so its items are
# never facts or news on their own: each is a held news item claim marked
# as a lead, in Data Quality's work ("Not yours yet" on Checks), left out of
# the admin's counts, and refused if anyone tries to approve it as it is
# (Review::LEAD). Data Quality turns a lead into a claim from the primary
# source (the company's release, the NRC's notice) or rejects it (PM, 22 Oct).
#
# Crawl and reading the feed are the newsrooms' (CompanyNewsrooms): once a
# day through the shared Fetcher, a block recorded and skipped. Only the
# last WINDOW_DAYS of items, the title as the quote, no model asked, and no
# copying beyond the feed's own title and summary.
class DataQuality::Plugins::TradePress < DataQuality::Plugins::CompanyNewsrooms
  FEEDS = {
    "World Nuclear News" => "https://www.world-nuclear-news.org/rss",
    "ANS Nuclear Newswire" => "https://www.ans.org/news/feed/"
  }.freeze
  WINDOW_DAYS = 14
  # Newest first, at most this many a feed a night (DQ, 23 Oct): ~15 leads a night.
  PER_FEED = 8
  # A name shorter than this is too likely to be an ordinary word in a headline.
  MIN_NAME = 4

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new)
    super(fetcher:, feeds:, today:)
    @directory = directory
  end

  # Only an item whose headline or summary names a company or plant in the
  # directory becomes a lead; the rest (mostly news from elsewhere) aren't
  # proposed at all.
  def extract(source, _run)
    publisher = company_for(source) or return []
    since = @today.call - WINDOW_DAYS
    taken = decided_urls(source)
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }
      .sort_by { |item| item.published_on }.reverse.filter_map do |item|
        about = named_in("#{item.title} #{item.summary}")
        next if about.empty?

        { kind: "news_item", quote: item.title, payload: {
          "url" => item.url, "title" => item.title, "publisher" => publisher, "published_on" => item.published_on.iso8601,
          "summary" => item.summary, "about" => about, "lead" => true }.compact }
      end.first(PER_FEED)
  end

  def source_facts(source)
    publisher = company_for(source) or return
    "This is #{publisher}'s news feed, a trade publication reporting others' news. An item is a lead to the primary " \
      "source, not evidence on its own."
  end

  private
    # [{ "name", "type" }] for each published company or plant the text names, as a whole phrase.
    def named_in(text)
      @patterns ||= @directory.published_names.flat_map do |type, names|
        names.select { |name| name.length >= MIN_NAME }.map { |name| [ type, name, /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i ] }
      end
      @patterns.filter_map { |type, name, pattern| { "name" => name, "type" => type } if text.match?(pattern) }.uniq { |hit| hit["name"].downcase }
    end
end
