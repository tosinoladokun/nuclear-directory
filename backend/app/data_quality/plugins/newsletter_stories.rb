# Newsletter stories to their primary source (#792; Tosin, 18 Nov: "if there
# is a lead for a news or story, let us get it from there").
#
# Crawl: the links in the newsletter emails received in the last WINDOW_DAYS
# (the newsletters kind) that point at a primary source: a page on a directory
# company's own website, or a US government (.gov) page. The newsletter's own
# pages, trackers and social sites are never followed, and its text is never
# used. At most PER_RUN new pages a night, each fetched once (robots.txt and
# blocks respected, as everywhere).
#
# Extract: a page becomes a news item claim, cited to the page itself, only
# when it is about nuclear work (STRONG_NUCLEAR in its title or text), names a
# company or plant in the directory, and states its own publication date
# within WINDOW_DAYS. Anything else stays a lead only (the newsletters kind).
class DataQuality::Plugins::NewsletterStories < DataQuality::Plugin
  WINDOW_DAYS = 14
  PER_RUN = 20
  MIN_NAME = 4
  STRONG_NUCLEAR = DataQuality::Plugins::WirePress::STRONG_NUCLEAR
  NOT_FOLLOWED = DataQuality::Plugins::Newsletters::NOT_OWN
  # A page's own date: article meta, JSON-LD, then a <time> element.
  DATE_META = %w[article:published_time og:article:published_time datePublished date dc.date DC.date.issued].freeze

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new, today: -> { Date.current })
    @fetcher, @directory, @today = fetcher, directory, today
  end

  def crawl(_run)
    known = Source.where(url: story_links).pluck(:url).to_set
    fresh = story_links.reject { |url| known.include?(url) }.first(PER_RUN)
    results = fresh.map do |url|
      source = Source.create!(url:, source_kind:)
      DataQuality::Snapshot.take(source, fetcher: @fetcher).to_s
    end
    { "links" => story_links.size, "fetched" => fresh.size }.merge(results.tally)
  end

  def extract(source, _run)
    return [] unless source.crawl_ok? && source.content_text.present?

    doc = Nokogiri::HTML(source.content_text)
    title = page_title(doc)
    text = visible_text(source)
    published = published_on(doc)
    return [] if title.blank? || published.nil? || published < @today.call - WINDOW_DAYS || published > @today.call
    named = named_in("#{title} #{text}")
    return [] if named.empty?
    # Nuclear work beyond the names ("Acme Fission Opens Office" isn't).
    words = named.reduce("#{title} #{text.first(3_000)}") { |all, hit| all.gsub(/#{Regexp.escape(hit['name'])}/i, " ") }
    return [] unless words.match?(STRONG_NUCLEAR)
    # A broad company's page (Google, Amazon, NASA…) says nuclear in its title, not once in passing (DQ, 20 Nov).
    return [] if broad?(source, named) && !named.reduce(title) { |all, hit| all.gsub(/#{Regexp.escape(hit['name'])}/i, " ") }.match?(STRONG_NUCLEAR)

    [ { kind: "news_item", quote: title, payload: {
      "url" => source.final_url.presence || source.url, "title" => title, "publisher" => publisher(source, doc),
      "published_on" => published.iso8601, "about" => named.first(5) } } ]
  end

  # The quote is the page's own title, which may sit only in its <head> (Copilot).
  def quote_in_source?(source, quote)
    quote.present? && (page_title(Nokogiri::HTML(source.content_text.to_s)) == quote.squish || super)
  end

  def verification_context(source, quote)
    "Page title: #{page_title(Nokogiri::HTML(source.content_text.to_s))}\n#{visible_text(source).first(3_000)}"
  end

  def source_facts(_source)
    "This is the primary source a nuclear newsletter story linked to: the page itself (a company's own site or a US " \
      "government page), with its own title and date. The newsletter is never cited."
  end

  private
    def page_title(doc) = (doc.at("meta[property='og:title']")&.[]("content") || doc.at("title")&.text).to_s.squish

    # Primary-source links from recent newsletter emails, newest email first.
    def story_links
      @story_links ||= begin
        own = @directory.organizations_with_website.filter_map { |_, site| host_of(site) }.to_set
        emails = Source.where(source_kind: "newsletters", crawl_status: "ok", fetched_at: (@today.call - WINDOW_DAYS).beginning_of_day..)
          .order(fetched_at: :desc).pluck(:content_text)
        emails.flat_map { |text| text.to_s.split(DataQuality::Plugins::Newsletters::LINKS, 2).last.to_s.lines.map(&:strip) }
          .grep(%r{\Ahttps?://}i).select { |url| primary?(url, own) }.uniq
      end
    end

    # A page (not a home page) on a directory company's site or a .gov site.
    def primary?(url, own)
      uri = URI.parse(url)
      host = uri.host.to_s.downcase.delete_prefix("www.")
      return false if host.blank? || host.match?(NOT_FOLLOWED) || uri.path.to_s.delete("/").empty?

      host.end_with?(".gov") || own.include?(host)
    rescue URI::InvalidURIError
      false
    end

    BROAD = DataQuality::Plugins::CompanyNewsrooms::BROAD

    # On a broad company's site, or naming only broad companies.
    def broad?(source, named)
      owner = @directory.organizations_with_website.find { |_, site| host_of(site) == host_of(source.url) }&.first
      broad = ->(name) { BROAD.any? { |b| name.to_s.match?(/\A#{Regexp.escape(b)}(?![[:alnum:]])/i) } }
      (owner && broad.(owner)) || named.select { |hit| hit["type"] == "organization" }.then { |orgs| orgs.any? && orgs.all? { |hit| broad.(hit["name"]) } }
    end

    def host_of(url) = (URI.parse(url.to_s.strip).host.to_s.downcase.delete_prefix("www.").presence rescue nil)

    def published_on(doc)
      values = DATE_META.flat_map { |name| doc.css("meta[property='#{name}'], meta[name='#{name}'], meta[itemprop='#{name}']").map { |meta| meta["content"] } }
      values += doc.css("script[type='application/ld+json']").flat_map { |script| script.text.scan(/"datePublished"\s*:\s*"([^"]+)"/).flatten }
      values += doc.css("time[datetime]").first(1).map { |time| time["datetime"] }
      values.compact.lazy.filter_map { |value| Date.parse(value) rescue nil }.first
    end

    # The site's own name (og:site_name), else the company whose site it is, else its host.
    def publisher(source, doc)
      doc.at("meta[property='og:site_name']")&.[]("content").to_s.squish.presence ||
        @directory.organizations_with_website.find { |_, site| host_of(site) == host_of(source.url) }&.first ||
        host_of(source.url)
    end

    def named_in(text)
      @patterns ||= @directory.published_names.flat_map do |type, names|
        names.select { |name| name.length >= MIN_NAME }.map { |name| [ type, name, /(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/i ] }
      end
      # A short all-capitals name (TVA) only as a whole word in capitals, as wire_press reads it (Copilot).
      @acronyms ||= @directory.published_names.flat_map do |type, names|
        names.select { |name| name.length < MIN_NAME && name.match?(/\A[A-Z0-9&]{2,3}\z/) }.map { |name| [ type, name ] }
      end
      long = @patterns.filter_map { |type, name, pattern| { "name" => name, "type" => type } if text.match?(pattern) }
      short = @acronyms.filter_map { |type, name| { "name" => name, "type" => type } if text.match?(/(?<![[:alnum:]])#{Regexp.escape(name)}(?![[:alnum:]])/) }
      (long + short).uniq { |hit| hit["name"].downcase }
    end
end
