# The U.S. Nuclear Regulatory Commission's news releases feed: NRC's own
# announcements (licences, construction permits, renewals, enforcement).
# NRC is the primary source for what it decides, so an item naming a
# company or plant in the directory becomes a news item claim about NRC and
# those records, never a lead. Read exactly as DOE's news is (#580): once a
# day, the last WINDOW_DAYS, at most PER_FEED a night, the title as the
# quote, an item naming nothing but NRC not proposed. The news releases
# page itself is drawn by script, so the feed NRC links from it is read.
class DataQuality::Plugins::NrcNews < DataQuality::Plugins::DoeNuclearNews
  AGENCY = "U.S. Nuclear Regulatory Commission"
  PUBLISHER = AGENCY
  FEEDS = { AGENCY => "https://www.nrc.gov/public-involve/rss?feed=news" }.freeze
  WINDOW_DAYS = 60
  PER_FEED = 15

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new)
    super
  end

  def source_facts(_source)
    "This is the U.S. Nuclear Regulatory Commission's news releases feed: each item is NRC's own announcement, " \
      "with its title, date and link."
  end
end
