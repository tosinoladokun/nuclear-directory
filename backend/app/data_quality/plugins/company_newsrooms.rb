# Companies' own newsrooms (#128): each company's RSS feed of its own
# releases. A company's release is the primary source for its own
# announcement, so each item becomes a news item claim (#137) about that
# company, waiting for a person's approval like any claim (Tosin, 21 Oct:
# approve each).
#
# Crawl fetches each feed in FEEDS at most once a day through the shared
# Fetcher; a block is recorded and that feed is skipped, never worked around.
# A feed that isn't RSS or Atom is marked needs_human.
#
# Extract reads the feed's items published in the last WINDOW_DAYS: title,
# link, date and the feed's own summary. The quote is the item's title as
# the feed gives it. No model is asked, and nothing but the news item is
# proposed: partners a release names are left for a person (or a later
# reader) to find in the release itself.
class DataQuality::Plugins::CompanyNewsrooms < DataQuality::Plugin
  # Only feeds the company publishes itself, of its news or press releases
  # (not a blog of explainers), that answer our bot. Company => feed.
  FEEDS = {
    "Cameco" => "https://www.cameco.com/rss/news",
    "Holtec International" => "https://holtecinternational.com/feed/",
    "Deep Isolation" => "https://www.deepisolation.com/feed/",
    "TAE Technologies" => "https://tae.com/feed/"
  }.freeze
  WINDOW_DAYS = 60
  SUMMARY_LENGTH = 400
  NOT_A_FEED = "Not an RSS or Atom feed; the address may have moved"

  Item = Data.define(:title, :url, :published_on, :summary)

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current })
    @fetcher = fetcher
    @feeds = feeds
    @today = today
  end

  def crawl(_run)
    @feeds.each_with_object({}) do |(company, url), stats|
      feed = Source.find_or_create_by!(url:) do |source|
        source.source_kind = source_kind
        source.title = "#{company}: news feed"
      end
      outcome = DataQuality::Snapshot.take(feed, fetcher: @fetcher).to_s
      stats[company] = outcome
      next unless feed.crawl_ok? && feed.content_text.present?

      next if items(feed.content_text)

      feed.update!(crawl_status: "needs_human", status_reason: NOT_A_FEED)
      stats[company] = "not_a_feed"
    end
  end

  def extract(source, _run)
    company = company_for(source) or return []
    since = @today.call - WINDOW_DAYS
    taken = decided_urls(source)
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }.map do |item|
      { kind: "news_item", quote: item.title, payload: {
        "url" => item.url, "title" => item.title, "publisher" => company, "published_on" => item.published_on.iso8601,
        "summary" => item.summary, "about" => about(company, item) }.compact }
    end
  end

  # Items come and go from a feed as new ones push old ones out: none of that
  # says a news item stopped being true.
  def max_dropped_share(_source) = 0.0

  # The items extract reads, so a feed whose build date alone changed isn't read again.
  def rows_sha256(source)
    list = items(source.content_text) or return
    Digest::SHA256.hexdigest(list.map { |item| [ item.url, item.title, item.published_on, item.summary ].join("\t") }.join("\n"))
  end

  def quote_in_source?(source, quote) = Array(items(source.content_text)).any? { |item| item.title == quote.to_s.squish }

  def verification_context(source, quote)
    item = Array(items(source.content_text)).find { |each| each.title == quote.to_s.squish } or return
    [ item.title, item.published_on&.iso8601, item.url, item.summary ].compact.join("\n")
  end

  def source_facts(source)
    company = company_for(source) or return
    "This is #{company}'s own news feed: each item is a release #{company} published, with its title, date and link."
  end

  # A company the release names by its legal form ("Acme Fission, Inc.",
  # "Bright Power LLC"): a partner worth a lead. Up to six capitalised words
  # before the suffix; no model is asked.
  LEGAL = "Inc|LLC|L\\.L\\.C|Corp|Corporation|Ltd|Limited|PLC|plc|GmbH|S\\.A|AG"
  WORD = "(?!(?:#{LEGAL})\\b)[A-Z][\\w&'-]*"
  PARTNER = /\b((?:#{WORD}\s+){0,5}#{WORD}),?\s+(?:#{LEGAL})\b\.?/

  private
    # The company itself, then every other company the release names by its
    # legal form. Match keeps the ones the directory has; the others become
    # leads for Data Quality (LeadSync's news feed), never facts.
    def about(company, item)
      partners = [ item.title, item.summary ].compact.flat_map do |text|
        text.to_enum(:scan, PARTNER).map { partner_name(Regexp.last_match[0]) }
      end
      names = [ company, *partners ].uniq { |name| name.downcase.gsub(/[^a-z0-9]/, "") }
      names.reject! { |name| name != company && name.downcase.start_with?(company.downcase) }
      names.map { |name| { "name" => name, "type" => "organization" } }
    end

    # A Title Case headline capitalises its verbs too ("Cameco Signs Agreement
    # With Bright Fuel Holdings, Inc."): the name starts after the last joining
    # word.
    JOINING = /\b(?:with|and|by|from|for|to|between|acquires|selects|names|of)\s+/i

    def partner_name(match)
      name = match.strip.delete_suffix(".")
      last = name.to_enum(:scan, JOINING).map { Regexp.last_match.end(0) }.last
      (last ? name[last..] : name).sub(/\AThe\s+/, "")
    end

    def company_for(source) = @feeds.key(source.url)

    # Items from this feed a person or match already has: a claim that isn't
    # one extract replaces on every read. Re-reading the feed doesn't send
    # them back to the queue.
    # Across every feed of this kind, so a feed that moved address (Holtec's,
    # TAE's) doesn't propose its old items again.
    def decided_urls(_source)
      Candidate.joins(:source).where(sources: { source_kind: }, kind: "news_item").where.not(status: "new")
        .reject { |claim| claim.status_needs_review? && claim.review_origin == "extract" }
        .to_set { |claim| claim.payload["url"] }
    end

    # The feed's items, or nil when the text isn't RSS or Atom.
    def items(text)
      doc = Nokogiri::XML(text.to_s)
      doc.remove_namespaces!
      if doc.at_xpath("/rss/channel")
        own_summaries(doc.xpath("/rss/channel/item").filter_map { |node| item(node, link: node.at_xpath("link")&.text, date: node.at_xpath("pubDate")&.text, summary: node.at_xpath("description")&.text) })
      elsif doc.at_xpath("/feed")
        own_summaries(doc.xpath("/feed/entry").filter_map do |node|
          link = node.at_xpath("link[@rel='alternate']/@href") || node.at_xpath("link/@href")
          item(node, link: link&.value, date: (node.at_xpath("published") || node.at_xpath("updated"))&.text, summary: node.at_xpath("summary")&.text)
        end)
      end
    end

    # A summary the feed repeats under other items isn't about this one
    # (Cameco's feed gives every item its newest release's text): left out.
    def own_summaries(items)
      repeated = items.filter_map(&:summary).tally.select { |_, count| count > 1 }.keys
      items.map { |item| repeated.include?(item.summary) ? item.with(summary: nil) : item }
    end

    def item(node, link:, date:, summary:)
      title = node.at_xpath("title")&.text.to_s.squish
      url = link.to_s.strip
      return if title.blank? || !url.match?(%r{\Ahttps?://}i)

      Item.new(title:, url:, published_on: date_of(date), summary: plain(summary))
    end

    def date_of(text)
      Date.parse(text) if text.present?
    rescue Date::Error
      nil
    end

    # The feed's summary as plain text, cut at a word.
    def plain(html)
      text = Nokogiri::HTML.fragment(html.to_s).text.squish
      text.presence&.truncate(SUMMARY_LENGTH, separator: " ")
    end
end
