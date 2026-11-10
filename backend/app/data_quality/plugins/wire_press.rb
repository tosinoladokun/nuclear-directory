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
  # The wire carries all energy news: only strong nuclear words (DQ, 3 Nov),
  # not the newsrooms' wider list (plasma, enrichment, repository, radiation…).
  STRONG_NUCLEAR = /\b(?:nuclear|reactors?|microreactors?|uranium|fission|fusion|SMRs?|HALEU|TRISO|NRC|radioisotopes?|spent fuel)\b/i

  def initialize(fetcher: DataQuality::Fetcher.new, feeds: FEEDS, today: -> { Date.current }, directory: DataQuality::DirectoryClient.new, now: -> { Time.current })
    super(fetcher:, feeds:, today:, directory:)
    @now = now
  end

  # New companies (Tosin, 10 Nov): a nuclear release naming no company we
  # have is read once, at most RELEASES_PER_READ a read; its "About <Company>"
  # paragraph proposes that company with the website its own boilerplate
  # links. Never a guessed domain: no link there, no claim.
  RELEASES_PER_READ = 5
  RELEASE_URL = %r{\Ahttps://www\.prnewswire\.com/news-releases/}

  def crawl(_run)
    stats = @feeds.each_with_object({}) do |(name, url), stats|
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = "#{name}: news releases"
      end
      stats[name] = DataQuality::Snapshot.claim(source) { read(source) }.to_s
    end
    releases = unnamed_nuclear_items.first(RELEASES_PER_READ)
    releases.each do |item|
      release = Source.create!(url: item.url, source_kind:, title: item.title.truncate(250))
      DataQuality::Snapshot.take(release, fetcher: @fetcher)
    end
    stats["releases"] = releases.size if releases.any?
    stats
  end

  def extract(source, run)
    return release_claims(source) if source.url.match?(RELEASE_URL)

    since = @today.call - WINDOW_DAYS
    # Decided, or waiting from the other wire feed (a release both carry is proposed once).
    taken = decided_urls(source) + Candidate.joins(:source).where(sources: { source_kind: }, kind: "news_item", status: "new")
      .where.not(source_id: source.id).pluck(Arel.sql("candidates.payload->>'url'")).compact
    Array(items(source.content_text)).select { |item| item.published_on && item.published_on >= since && !taken.include?(item.url) }
      .select { |item| "#{item.title} #{item.summary}".match?(STRONG_NUCLEAR) }
      .sort_by(&:published_on).reverse.filter_map do |item|
        named = named_in("#{item.title} #{item.summary}")
        next if named.empty?

        { kind: "news_item", quote: item.title, payload: {
          "url" => item.url, "title" => item.title, "publisher" => PUBLISHER, "published_on" => item.published_on.iso8601,
          "summary" => item.summary, "about" => named }.compact }
      end.first(PER_FEED)
  end

  private

  # Nuclear items in the stored feeds that name no company we have, not yet read.
  def unnamed_nuclear_items
    since = @today.call - WINDOW_DAYS
    feeds = Source.where(url: @feeds.values).filter_map(&:content_text)
    items = feeds.flat_map { |text| Array(items(text)) }.uniq(&:url)
      .select { |item| item.published_on && item.published_on >= since && item.url.match?(RELEASE_URL) }
      .select { |item| "#{item.title} #{item.summary}".match?(STRONG_NUCLEAR) && named_in("#{item.title} #{item.summary}").empty? }
    read = Source.where(url: items.map(&:url)).pluck(:url)
    items.reject { |item| read.include?(item.url) }.sort_by(&:published_on).reverse
  end

  ABOUT = /\AAbout\s+(.{2,80}?)\s*:?\z/
  # The issuer's own "About <Company>" paragraph: a new company when it
  # states nuclear work, links the company's own https site and isn't in
  # the directory. Its description, HQ and category come from that site
  # (Enrich, the same night).
  def release_claims(source)
    return [] if source.content_text.blank?

    body = Nokogiri::HTML(source.content_text).at_css("section.release-body, .release-body") or return []
    paragraphs = body.css("p, h2, h3, b, strong").to_a
    paragraphs.each_with_index.filter_map do |heading, index|
      name = heading.text.squish[ABOUT, 1] or next
      next if name.match?(/\A(?:the|this|us)\b/i) || @directory.organization(name:)

      about = paragraphs[(index + 1)..].find { |node| node.name == "p" && node.text.squish.length > 40 } or next
      # The quote is the paragraph's opening text, before its first link or markup, as the page shows it.
      text = about.children.take_while(&:text?).map(&:text).join.squish
      next unless text.match?(STRONG_NUCLEAR) && text.downcase.include?(name.downcase.split.first.to_s)

      website = about.css("a[href]").filter_map { |link| own_site(link["href"]) }.first or next
      { kind: "organization", quote: text.truncate(300, separator: " ", omission: "").strip, payload: { "name" => name, "website" => website } }
    end.uniq { |claim| claim[:payload]["name"] }
  end

  BOILERPLATE_HOSTS = /(?:\A|\.)(?:prnewswire|cision|linkedin|twitter|x|facebook|youtube|instagram|sec)\.(?:com|gov)\z/
  def own_site(href)
    uri = URI.parse(href.to_s.strip)
    return unless %w[http https].include?(uri.scheme) && uri.host.present?

    host = uri.host.downcase
    host.match?(BOILERPLATE_HOSTS) ? nil : "https://#{host}"
  rescue URI::InvalidURIError
    nil
  end

  # Also a short all-capitals name in the directory (TVA, EPRI is long
  # enough already), as a whole word in capitals: never an ordinary word.
  def named_in(text)
    @acronyms ||= @directory.published_names.flat_map do |type, names|
      names.select { |name| name.length < MIN_NAME && name.match?(/\A[A-Z0-9&]{2,3}\z/) }.map { |name| [ type, name ] }
    end
    short = @acronyms.filter_map { |type, name| { "name" => name, "type" => type } if text.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/) }
    (super + short).uniq { |hit| hit["name"].downcase }
  end

  public

  # A release page is checked as any page: its quote in the visible text.
  def quote_in_source?(source, quote)
    return super unless source.url.match?(RELEASE_URL)

    quote.present? && visible_text(source).include?(quote.squish)
  end

  def verification_context(source, quote)
    return super unless source.url.match?(RELEASE_URL)

    text = visible_text(source)
    at = text.index(quote.to_s.squish) or return
    text[[ at - 1_500, 0 ].max, 3_000]
  end

  def source_facts(source)
    if source.url.match?(RELEASE_URL)
      return "This is one news release on PR Newswire, issued by the company it is about; its \"About\" paragraph is the " \
        "issuer's own description of itself and links its website."
    end


    "This is PR Newswire's feed of news releases: each item is a release a company issued through PR Newswire, with " \
      "its title, date, link and the release's opening words."
  end

  private
    # Every READ_HOURS: the feed's items merged into those kept, newest WINDOW_DAYS, stored as RSS.
    def read(source)
      # One time for the guard and the record, taken before the request, so an on-time run is never skipped.
      started = @now.call
      return :skipped_recent if source.fetched_at && source.fetched_at > started - READ_HOURS.hours + 5.minutes

      response = @fetcher.get(source.url)
      attempt = { fetched_at: started, http_status: response.status }
      unless response.kind == :ok
        streak = response.kind == :blocked ? source.blocked_streak + 1 : source.blocked_streak
        status = response.kind == :disallowed || streak >= DataQuality::Snapshot::BLOCKED_STREAK_LIMIT ? "needs_human" : (response.kind == :blocked ? "blocked" : source.crawl_status)
        source.update!(attempt.merge(status_reason: response.reason, blocked_streak: streak, crawl_status: status))
        return response.kind
      end

      fresh = items(response.body) or (source.update!(attempt.merge(crawl_status: "needs_human", status_reason: NOT_A_FEED)) && (return :needs_human))
      since = @today.call - WINDOW_DAYS
      kept = (fresh + Array(items(source.content_text))).uniq(&:url).select { |item| item.published_on && item.published_on >= since }
        .sort_by { |item| [ item.published_on, item.url ] }.reverse
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
