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
  # Every other published company's feed is found from its homepage: the
  # RSS or Atom link the homepage itself advertises (<link rel="alternate">),
  # on the company's own domain. At most DISCOVER_PER_NIGHT homepages are
  # read a night, each again after REDISCOVER_DAYS; a found feed is read
  # like the ones above from the next night on (Tosin, 28 Oct: crawl more).
  HOMEPAGE_KIND = "newsroom_homepage"
  DISCOVER_PER_NIGHT = 10
  REDISCOVER_DAYS = 30
  NEW_FEEDS_PER_NIGHT = 5
  # A found feed proposes only its newest items from before it was found
  # (DQ, 28 Oct): its back catalogue is old news, each item Tosin's to approve.
  FIRST_READ_ITEMS = 3
  # Only news about nuclear becomes a claim (Tosin, 29 Oct: an Amazon Alexa
  # release reached his inbox): see about_nuclear?.
  NUCLEAR = /\b(?:nuclear|reactors?|microreactors?|uranium|fission|fusion|SMRs?|HALEU|TRISO|NRC|radioisotopes?|isotopes?|radioactive|radiation|enrichment|spent fuel|decommissioning|borehole|repository|tritium|deuterium|plasma|FRC)\b/i
  # Companies whose news is mostly not nuclear: their items need a nuclear word.
  BROAD = [ "Amazon", "Google", "Alphabet", "Meta", "Microsoft", "Apple", "Oracle", "Nvidia", "Dow", "3M", "Siemens",
    "General Electric", "GE Vernova", "GE Aerospace", "GE HealthCare", "Hitachi", "Honeywell", "Lockheed Martin", "Boeing", "Caterpillar", "Duke Energy", "Southern Company",
    "Leidos", "Eni", "Entergy", "Samsung", "Equinix", "Crusoe", "Switch", "Curtiss-Wright", "Kiewit", "Hyundai" ].freeze
  # A publisher only in these roles isn't a nuclear company: its items need a nuclear word too (DQ).
  NON_NUCLEAR_ROLES = %w[data_center_offtaker venture_capital].freeze
  WINDOW_DAYS = 60
  SUMMARY_LENGTH = 400
  NOT_A_FEED = "Not an RSS or Atom feed; the address may have moved"

  Item = Data.define(:title, :url, :published_on, :summary)

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, discover: nil, directory: nil)
    @fetcher = fetcher
    @feeds = feeds
    @today = today
    # Only the companies' own newsrooms, with the standard list, are found
    # from homepages; trade press and agency news read their fixed feeds.
    @discover = discover.nil? ? instance_of?(DataQuality::Plugins::CompanyNewsrooms) && feeds.equal?(FEEDS) : discover
    @directory = directory || DataQuality::DirectoryClient.new
  end

  # The fixed feeds, then every feed found from a homepage.
  def feeds
    return @feeds unless @discover

    found = Source.where(source_kind: HOMEPAGE_KIND, crawl_status: "ok").filter_map { |page| discovered(page.content_text) }.to_h
    found.reject { |company, url| @feeds.key?(company) || @feeds.value?(url) }.then { |extra| @feeds.merge(extra) }
  end

  def new_sources_per_run = (NEW_FEEDS_PER_NIGHT if @discover)

  def crawl(_run)
    stats = @discover ? discover : {}
    feeds.each_with_object(stats) do |(company, url), stats|
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
    recent = Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }
    recent = since_found(source, recent) if found_feed?(company)
    recent.select { |item| about_nuclear?(company, item) }.map do |item|
      { kind: "news_item", quote: item.title, payload: {
        "url" => item.url, "title" => item.title, "publisher" => company, "published_on" => item.published_on.iso8601,
        "summary" => item.summary, "about" => about(company, item, directory_only: found_feed?(company)) }.compact }
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
    # Every item must name nuclear work, or (for a publisher that isn't broad
    # or only a data-center buyer or investor) another record we have. The
    # listed feeds too (DQ, 29 Oct: dates and investor conferences got through).
    def about_nuclear?(company, item)
      text = "#{item.title} #{item.summary}"
      return true if text.match?(NUCLEAR)
      return false if broad?(company) || non_nuclear_publisher?(company)

      names_another_record?(company, text)
    end

    # A name starting with a broad company's as a whole word ("Eni", not "Enigma").
    def broad?(company) = BROAD.any? { |broad| company.to_s.match?(/\A#{Regexp.escape(broad)}(?![[:alnum:]])/i) }

    def non_nuclear_publisher?(company)
      record = @directory.organization(name: company) or return false
      roles = @directory.role_keys(record.id)
      roles.any? && (roles - NON_NUCLEAR_ROLES).empty?
    end

    # A company or plant we have, other than the publisher, named as a whole phrase.
    def names_another_record?(company, text)
      @named_patterns ||= @directory.published_names.flat_map do |_type, names|
        names.select { |name| name.length >= 4 }.map { |name| [ name, /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i ] }
      end
      publisher = @directory.organization(name: company)&.id
      @named_patterns.any? do |name, pattern|
        next false if name.casecmp?(company) || company.downcase.start_with?(name.downcase) || !text.match?(pattern)

        # Any of the publisher's own names (a longer legal-name alias) isn't another record.
        publisher.nil? || @directory.organization(name:)&.id != publisher
      end
    end

    def found_feed?(company) = @discover && !@feeds.key?(company)

    # A found feed's items published since it was found, and only the newest
    # FIRST_READ_ITEMS of those before: the same on every read, so its back
    # catalogue never comes in later.
    def since_found(source, items)
      found_on = source.created_at.to_date
      before, after = items.partition { |item| item.published_on < found_on }
      (after + before.sort_by(&:published_on).last(FIRST_READ_ITEMS)).sort_by(&:published_on).reverse
    end

    # Reads up to DISCOVER_PER_NIGHT homepages not read in REDISCOVER_DAYS,
    # never-read ones first, storing each as "Company: …" and "Feed: …" lines.
    def discover
      pages = @directory.organizations_with_website.filter_map do |company, website|
        next if @feeds.key?(company)

        url = homepage(website) or next
        # Its own row ("#newsroom"), apart from any homepage the directory
        # cites as evidence: the fetch is the same page, the record isn't.
        page = Source.find_or_create_by!(url: "#{url}#newsroom") do |row|
          row.source_kind = HOMEPAGE_KIND
          row.title = "#{company}: homepage (newsroom feed)"
        end
        [ company, page ] if page.fetched_at.nil? || page.fetched_at < REDISCOVER_DAYS.days.ago
      rescue ActiveRecord::RecordInvalid
        nil
      end
      read = pages.sort_by { |_, page| page.fetched_at || Time.at(0) }.first(DISCOVER_PER_NIGHT)
      # The company's name from the directory, never the page's title.
      found = read.count do |company, page|
        DataQuality::Snapshot.take(page, fetcher: @fetcher) { |html| "Company: #{company}\nFeed: #{feed_link(html, page.url) || 'none'}" }
        discovered(page.reload.content_text)
      end
      { "homepages_read" => read.size, "feeds_found" => found }
    end

    def homepage(website)
      uri = URI.parse(website.to_s.strip.then { |text| text.match?(%r{\Ahttps?://}i) ? text : "https://#{text}" })
      "#{uri.scheme}://#{uri.host}/" if uri.host.present?
    rescue URI::InvalidURIError
      nil
    end

    # The homepage's advertised RSS or Atom feed on the company's own domain,
    # not a comments feed.
    def feed_link(html, page_url)
      host = URI.parse(page_url).host.sub(/\Awww\./, "")
      Nokogiri::HTML(html.to_s).css('link[rel~="alternate"]').filter_map do |link|
        next unless link["type"].to_s.match?(%r{application/(rss|atom)\+xml}i)

        url = URI.join(page_url, link["href"].to_s.strip).to_s
        url if URI.parse(url).host.to_s.sub(/\Awww\./, "").then { |own| own == host || own.end_with?(".#{host}") } && !url.match?(/comments/i)
      rescue URI::Error
        nil
      end.first
    end

    def discovered(text)
      lines = text.to_s.lines.map(&:chomp).to_h { |line| line.split(": ", 2) }
      [ lines["Company"], lines["Feed"] ] if lines["Company"].present? && lines["Feed"].to_s.start_with?("http")
    end

    # The company itself, then every other company the release names by its
    # legal form. Match keeps the ones the directory has; the others become
    # leads for Data Quality (LeadSync's news feed), never facts.
    # A found feed names only partners the directory has (DQ, 28 Oct: a
    # company blog's legal-suffix names are too noisy to become leads).
    def about(company, item, directory_only: false)
      partners = [ item.title, item.summary ].compact.flat_map do |text|
        text.to_enum(:scan, PARTNER).map { partner_name(Regexp.last_match[0]) }
      end
      names = [ company, *partners ].uniq { |name| name.downcase.gsub(/[^a-z0-9]/, "") }
      names.reject! { |name| name != company && name.downcase.start_with?(company.downcase) }
      names.select! { |name| name == company || @directory.organization(name:) } if directory_only
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

    def company_for(source) = feeds.key(source.url)

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
