# The U.S. Department of Energy's Office of Nuclear Energy news feed: DOE's
# own announcements (awards, HALEU allocations, reactor milestones, loans).
# DOE is the primary source for what it announces, so each item is a news
# item claim (#137) about DOE and every company or plant in the directory it
# names, waiting for a person's approval like any news. Unlike trade press
# (whose reading of names it shares), these are never leads.
#
# Read like the newsrooms: once a day through the shared Fetcher, a block
# recorded and skipped, the last WINDOW_DAYS of items, the title as the
# quote. An item naming nothing in the directory besides DOE isn't proposed.
# No model is asked.
class DataQuality::Plugins::DoeNuclearNews < DataQuality::Plugins::TradePress
  DOE = "U.S. Department of Energy"
  FEEDS = { DOE => "https://www.energy.gov/ne/rss.xml" }.freeze
  WINDOW_DAYS = 60
  PER_FEED = 15

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new)
    super
  end

  def extract(source, _run)
    company_for(source) or return []
    since = @today.call - WINDOW_DAYS
    taken = decided_urls(source)
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }
      .sort_by(&:published_on).reverse.filter_map do |item|
        named = named_in("#{item.title} #{item.summary}").reject { |hit| hit["name"].casecmp?(DOE) }
        next if named.empty?

        { kind: "news_item", quote: item.title, payload: {
          "url" => item.url, "title" => item.title, "publisher" => "#{DOE}, Office of Nuclear Energy",
          "published_on" => item.published_on.iso8601, "summary" => item.summary,
          "about" => [ { "name" => DOE, "type" => "organization" }, *named ] }.compact }
      end.first(PER_FEED)
  end

  def source_facts(_source)
    "This is the U.S. Department of Energy's Office of Nuclear Energy news feed: each item is DOE's own " \
      "announcement, with its title, date and link."
  end
end
