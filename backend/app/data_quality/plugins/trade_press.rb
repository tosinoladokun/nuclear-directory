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

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current })
    super
  end

  def extract(source, _run)
    publisher = company_for(source) or return []
    since = @today.call - WINDOW_DAYS
    taken = decided_urls(source)
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }.map do |item|
      { kind: "news_item", quote: item.title, payload: {
        "url" => item.url, "title" => item.title, "publisher" => publisher, "published_on" => item.published_on.iso8601,
        "summary" => item.summary, "about" => [], "lead" => true }.compact }
    end
  end

  def source_facts(source)
    publisher = company_for(source) or return
    "This is #{publisher}'s news feed, a trade publication reporting others' news. An item is a lead to the primary " \
      "source, not evidence on its own."
  end
end
