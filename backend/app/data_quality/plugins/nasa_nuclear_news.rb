# NASA's own announcements about its nuclear work (fission surface power,
# the SR-1 Freedom space reactor, HALEU, radioisotope power), from NASA's
# news feed searched for fission. NASA is the primary source for what it
# announces, so an item whose title or summary is about nuclear work
# becomes a news item claim about NASA and every company or plant in the
# directory it names (never a lead).
#
# Read like the newsrooms: once a day through the shared Fetcher, the last
# WINDOW_DAYS, the title as the quote, at most PER_FEED a night. The search
# feed also returns unrelated stories, so an item counts only when its title
# names nuclear work (NUCLEAR) or its summary is about it (NUCLEAR_WORK): a
# story that only mentions a nuclear-powered rover doesn't. No model is asked; every item waits for a person.
class DataQuality::Plugins::NasaNuclearNews < DataQuality::Plugins::TradePress
  NASA = "NASA"
  FEEDS = { NASA => "https://www.nasa.gov/?s=fission+surface+power&feed=rss2" }.freeze
  WINDOW_DAYS = 60
  PER_FEED = 10
  NUCLEAR = /\b(?:fission|nuclear|reactors?|HALEU|radioisotope|uranium|RTGs?|MMRTGs?)\b/i
  # In a summary only NASA's nuclear work itself counts, not a passing mention
  # ("the nuclear-powered rover" in a Mars rock story; PM, 15 Nov).
  NUCLEAR_WORK = Regexp.union(/\bfission (?:surface )?power\b/i, /\bspace (?:nuclear )?reactors?\b/i,
    /\bnuclear (?:propulsion|power systems?|thermal|electric|reactors?)\b/i, /\bradioisotope (?:power system|heater|thermoelectric)/i,
    /\b(?:MM)?RTGs?\b/, /\bHALEU\b/, /\bSR-1\b/, /\breactor (?:design|test|prototype|demonstration)/i)

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new)
    super
  end

  def extract(source, _run)
    company_for(source) or return []
    since = @today.call - WINDOW_DAYS
    taken = decided_urls(source)
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }
      .select { |item| item.title.to_s.match?(NUCLEAR) || about_nuclear_work?(item.summary) }
      .sort_by(&:published_on).reverse.map do |item|
        named = named_in("#{item.title} #{item.summary}").reject { |hit| hit["name"].casecmp?(NASA) }
        { kind: "news_item", quote: item.title, payload: {
          "url" => item.url, "title" => item.title, "publisher" => NASA, "published_on" => item.published_on.iso8601,
          "summary" => item.summary, "about" => [ { "name" => NASA, "type" => "organization" }, *named ] }.compact }
      end.first(PER_FEED)
  end

  # Work on the nuclear system itself (Copilot): a summary sentence naming it
  # with what NASA does to it (tests, builds, fuels…), never one describing
  # something it powers ("the MMRTG-powered rover", "powered by an RTG").
  WORK = /\b(?:test(?:s|ed|ing)?|build(?:s|ing)?|buil[dt]|develop(?:s|ed|ing|ment)?|design(?:s|ed|ing)?|demonstrat\w*|fuel(?:s|ed|ing)?|deliver(?:s|ed|y)?|award(?:s|ed)?|contract\w*|select(?:s|ed)?|assembl\w*|advanc(?:e|es|ed|ing))\b/i
  POWERED = /\b(?:[\w-]+-powered|powered by|kept warm by|heated by)\b/i

  def about_nuclear_work?(summary)
    summary.to_s.split(/(?<=[.!?])\s+/).any? { |sentence| sentence.match?(NUCLEAR_WORK) && sentence.match?(WORK) && !sentence.match?(POWERED) }
  end

  def source_facts(_source)
    "This is NASA's news feed: each item is NASA's own announcement, with its title, date and link."
  end
end
