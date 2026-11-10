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
    "ANS Nuclear Newswire" => "https://www.ans.org/news/feed/",
    # Nuclear-only trade press (Tosin, 10 Nov); robots allow both.
    "NucNet" => "https://www.nucnet.org/feed",
    "Nuclear Engineering International" => "https://www.neimagazine.com/feed/"
  }.freeze
  # New companies (one lead pipeline, 10 Nov): a day's items naming nothing we
  # have are read by the model once, for US nuclear companies, each a lead.
  NEW_NAMES_DAYS = 1
  NAMES_PER_FEED = 10
  PROMPT_VERSION = "trade_press_names-1".freeze
  NAMES_INSTRUCTIONS = <<~TEXT.freeze
    You read nuclear trade press headlines and summaries. List the US companies whose own nuclear work an item reports
    (reactor developers, fuel, enrichment, suppliers, utilities running nuclear plants, isotopes, nuclear engineering,
    nuclear investors). Not agencies, national labs, universities, associations, people, or companies outside the US.
    For each: name exactly as written in the item, and the item number. Nothing else.
  TEXT
  WINDOW_DAYS = 14
  # Newest first, at most this many a feed a night (DQ, 23 Oct): ~15 leads a night.
  PER_FEED = 8
  # A name shorter than this is too likely to be an ordinary word in a headline.
  MIN_NAME = 4

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new, llm: nil)
    super(fetcher:, feeds:, today:)
    @directory, @llm = directory, llm
  end

  # Only an item whose headline or summary names a company or plant in the
  # directory becomes a lead; the rest (mostly news from elsewhere) aren't
  # proposed at all.
  def extract(source, run)
    publisher = company_for(source) or return []
    keep_new_names(source, publisher, run)
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
    def llm = @llm ||= DataQuality::OpenRouter::Client.new

    # The day's items that name nothing we have: their US nuclear companies
    # become leads (the lead finder finds and checks their sites). The
    # name must be in its item's own words.
    def keep_new_names(source, publisher, run)
      since = @today.call - NEW_NAMES_DAYS
      items = Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since }
        .select { |item| named_in("#{item.title} #{item.summary}").empty? }.first(NAMES_PER_FEED)
      return if items.empty?

      run&.update!(prompt_version: PROMPT_VERSION)
      listing = items.each_with_index.map { |item, i| "#{i + 1}. #{item.title}\n#{item.summary}" }.join("\n\n")
      found = llm.structured(role: :extract, schema: names_schema, schema_name: "trade_press_names", crawl_run: run, reasoning_effort: "low",
        messages: [ { role: "system", content: NAMES_INSTRUCTIONS }, { role: "user", content: listing } ]).data
      Array(found["companies"]).each do |company|
        item = items[company["item"].to_i - 1] or next
        name = company["name"].to_s.squish
        next if name.length < MIN_NAME || !"#{item.title} #{item.summary}".include?(name) || @directory.organization(name:)

        @directory.keep_lead(name:, key: "press:#{item.url}:#{name.downcase}", label: "#{publisher}: #{item.title.truncate(110)}", url: item.url)
      end
    end

    def names_schema
      { type: "object", additionalProperties: false, required: [ "companies" ], properties: { "companies" => { type: "array", items: {
        type: "object", additionalProperties: false, required: %w[name item],
        properties: { "name" => { type: "string" }, "item" => { type: "integer" } } } } } }
    end

    # [{ "name", "type" }] for each published company or plant the text names, as a whole phrase.
    def named_in(text)
      @patterns ||= @directory.published_names.flat_map do |type, names|
        names.select { |name| name.length >= MIN_NAME }.map { |name| [ type, name, /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i ] }
      end
      @patterns.filter_map { |type, name, pattern| { "name" => name, "type" => type } if text.match?(pattern) }.uniq { |hit| hit["name"].downcase }
    end
end
