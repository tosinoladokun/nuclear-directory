# The lead finder (one lead pipeline, Tosin 10 Nov; #752): turns a company
# lead from any source (Tosin's "Suggest a company", newsletters, trade
# press…) into a new-company claim, or says why it can't.
#
#   LeadFinder.call(lead_id) # => Outcome
#
# 1. Find the website, first-party only: a website given; a news link's
#    "About <Company>" paragraph link; SEC's ticker list (an exact name) and
#    the company's EDGAR record; then the web search API (Brave, at most
#    SEARCHES_PER_DAY a day, its results only candidates to check). A
#    LinkedIn link gives the name only: LinkedIn is never fetched.
# 2. Verify on the site's own home page (robots and blocks as everywhere):
#    it names the company, states nuclear work, and is in the US.
# 3. Dedupe by name, alias and domain against the directory.
# 4. Propose: the home page is stored as this kind's source (its title is the
#    company's name) and Extract + Match make the pending company, with its
#    website; Enrich reads it the same night (#751) for description, HQ and
#    category, and Data Quality checks it before Tosin's Create.
class DataQuality::Plugins::LeadFinder < DataQuality::Plugin
  Outcome = Data.define(:outcome, :candidate_id, :organization_id, :name, :website, :reason, :found)

  SEARCH_API = "https://api.search.brave.com/res/v1/web/search".freeze
  # Paid, no attribution credit (PM, 10 Nov): at most this many a day, ~$3 a month at $5 per 1,000.
  SEARCHES_PER_DAY = 20
  USAGE = "brave_searches".freeze
  # Leads found a day, whatever asks (Infra, 10 Nov: a pasted long list can't spend the quotas).
  FINDS_PER_DAY = 50
  FINDS = "finds".freeze
  SEARCH_RESULTS = 5
  NUCLEAR = DataQuality::Plugins::WirePress::STRONG_NUCLEAR
  US = /\b(?:United States|U\.S\.A?\.?|USA)\b|\b(?:A[LKZR]|C[AOT]|D[EC]|FL|GA|HI|I[ADLN]|K[SY]|LA|M[ADEINOST]|N[CDEHJMVY]|O[HKR]|PA|RI|S[CD]|T[NX]|UT|V[AT]|W[AIVY])\s+\d{5}\b/
  NEWS_HOSTS = /(?:\A|\.)(?:prnewswire|businesswire|globenewswire|accessnewswire|world-nuclear-news|ans|nucnet|neimagazine|utilitydive|reuters|bloomberg|yahoo)\.(?:com|org)\z/
  NOT_OWN = /(?:\A|\.)(?:linkedin|twitter|x|facebook|youtube|instagram|wikipedia|crunchbase|bloomberg|google|sec|prnewswire|cision)\.[a-z.]+\z/

  def self.call(lead_id, finder: new, input: nil) = finder.find(lead_id, input:)

  # Brave searches made in a month (each is a recorded crawl run), for PM's cost report:
  #   DataQuality::Plugins::LeadFinder.searches_in(Date.new(2026, 11))
  def self.searches_in(month) = CrawlRun.where(source_kind: "lead_finder", stage: "crawl")
    .where("stats ? '#{USAGE}'").where(started_at: month.beginning_of_month.all_month).count

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new, search: nil,
    search_key: ENV["BRAVE_SEARCH_API_KEY"], pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    @fetcher, @directory, @search, @search_key, @pipeline = fetcher, directory, search, search_key, pipeline
  end

  # Nothing to crawl on a schedule: each lead is found when asked.
  def crawl(_run) = {}

  # input: what Tosin typed (#752), read in place of the lead's name.
  def find(lead_id, input: nil)
    lead = @directory.lead(lead_id) or raise ArgumentError, "No lead #{lead_id}"
    if counted_today(FINDS) >= FINDS_PER_DAY
      return unconfirmed(input.presence || lead.name, nil, "Today's limit of #{FINDS_PER_DAY} finds is reached; tried again tomorrow", {})
    end

    CrawlRun.create!(source_kind:, stage: "crawl", status: "succeeded", finished_at: Time.current, stats: { FINDS => 1 })
    lead = lead.with(name: input) if input.present?
    found = {}
    name, links = read_input(lead)
    # A website alone: the name the site gives itself (its og:site_name, else its title's first part).
    name ||= site_name(links)
    found["name"] = name
    return unconfirmed(name, nil, "No company name to look for", found) if name.blank?

    if (known = @directory.organization(name:))
      return outcome(:duplicate, name:, organization_id: known.id, reason: "Already listed", found:)
    end

    candidates_for(name, links, found).each do |website|
      if (known = @directory.organization(domain: URI(website).host))
        return outcome(:duplicate, name:, website:, organization_id: known.id, reason: "Its website is already listed", found:)
      end
      verdict, page, why = verify(name, website)
      (found["checked"] ||= []) << { "verdict" => verdict.to_s, "why" => why }.merge(found.key?("searched") ? {} : { "website" => website })
      next unless verdict == :ok

      return propose(name, website, page, found)
    end
    unconfirmed(name, nil, found["checked"] ? "No site checked out as this US nuclear company" : "No website found", found)
  end

  # The pending company, from the verified home page.
  def extract(source, _run)
    name = source.title.to_s.squish
    return [] if name.blank? || source.content_text.blank?

    blocks = Nokogiri::HTML(source.content_text).css("p, li, h1, h2, h3, h4").map { |node| node.xpath(".//text()").map(&:text).join(" ").squish }
    quote = blocks.flat_map { |block| block.split(/(?<=[.!?])\s+/) }
      .find { |sentence| sentence.include?(name) && nuclear?(sentence, name) } or return []
    [ { kind: "organization", quote: quote.strip, payload: { "name" => name, "website" => "https://#{URI(source.url).host}" } } ]
  end

  def source_facts(_source)
    "This is a company's own home page, read to confirm the company a lead names: its name, its website and that it " \
      "does nuclear work."
  end

  private
    # Nuclear work stated beyond the company's own name ("Fresh Fission" alone isn't).
    def nuclear?(text, name) = text.gsub(/#{Regexp.escape(name)}/i, " ").match?(NUCLEAR)

    def outcome(kind, name:, found:, website: nil, organization_id: nil, candidate_id: nil, reason: nil)
      Outcome.new(outcome: kind, candidate_id:, organization_id:, name:, website:, reason:, found:)
    end

    def unconfirmed(name, website, reason, found) = outcome(:unconfirmed, name:, website:, reason:, found:)

    # The name to look for, and links to read: Tosin's raw input may be a link.
    def read_input(lead)
      links = lead.urls.dup
      name = lead.name.to_s.squish
      if name.match?(%r{\Ahttps?://}i)
        links.unshift(name)
        name = nil
      end
      links.each do |link|
        slug = link[%r{linkedin\.com/company/([^/?#]+)}i, 1] and name ||= slug.tr("-_", " ").squish.titleize
      end
      [ name, links.reject { |link| link.match?(/linkedin\.com/i) } ]
    end

    def site_name(links)
      site = links.filter_map { |link| own_host(link) }.first or return
      page = snapshot(site) or return
      doc = Nokogiri::HTML(page.content_text)
      named = doc.at_css("meta[property='og:site_name']")&.[]("content").to_s.squish.presence ||
        doc.at_css("title")&.text.to_s.split(/\s+[|\u2013\u2014-]\s+/).first.to_s.squish.presence
      named if named && named.length.between?(2, 80)
    end

    # Websites to check, in order: given, a news link's About paragraph, EDGAR, search.
    def candidates_for(name, links, found)
      sites = []
      links.each do |link|
        host = (URI.parse(link).host.to_s.downcase rescue "")
        next if host.blank?

        if host.match?(NEWS_HOSTS)
          sites.concat(about_links(link, name))
        elsif !host.match?(NOT_OWN)
          sites << "https://#{host}"
        end
      end
      found["given"] = sites.dup if sites.any?
      if sites.empty? && (edgar = edgar_website(name))
        found["edgar"] = edgar
        sites << edgar
      end
      if sites.empty?
        # Brave's terms forbid keeping search results: only how many were checked is noted, and only a site
        # that then checks out on its own home page is kept (as the company's website).
        results = search(name)
        found["searched"] = results.size if results.any?
        sites.concat(results)
      end
      sites.uniq
    end

    # The "About <name>" paragraph's own links on a news page.
    def about_links(url, name)
      page = snapshot(url) or return []
      doc = Nokogiri::HTML(page.content_text)
      heading = doc.css("p, h2, h3, h4, b, strong").find { |node| node.text.squish.match?(/\AAbout\s+#{Regexp.escape(name)}\b/i) } or return []
      paragraph = heading.name == "p" && heading.css("a[href]").any? ? heading : heading.xpath("following::p[1]").first
      Array(paragraph&.css("a[href]")).filter_map { |a| own_host(a["href"]) }
    end

    # SEC's ticker list (as the Form D plug-in stores it): an exact name, then its EDGAR record's website.
    def edgar_website(name)
      list = Source.find_by(url: DataQuality::Plugins::SecTickerCiks::TICKERS_URL)&.content_text or return
      wanted = name.downcase.gsub(/[^a-z0-9]+/, " ").squish
      entries = JSON.parse(list).values.select { |entry| entry["title"].to_s.downcase.gsub(/[^a-z0-9]+/, " ").squish.sub(/ (inc|corp|co|llc|ltd)\z/, "") == wanted.sub(/ (inc|corp|co|llc|ltd)\z/, "") }
      return unless entries.map { |entry| entry["cik_str"] }.uniq.one?

      record = snapshot(format(DataQuality::Plugins::CompanyPages::EDGAR, entries.first["cik_str"].to_i)) or return
      own_host(JSON.parse(record.content_text)["website"].to_s.then { |site| site.match?(%r{\Ahttps?://}i) ? site : "https://#{site}" })
    rescue JSON::ParserError
      nil
    end

    # Brave Search API: at most SEARCHES_PER_DAY a day, top results' own hosts.
    def search(name)
      return [] if @search_key.blank? && @search.nil?
      return [] if searches_today >= SEARCHES_PER_DAY

      # Each search is recorded (never its results), so the cap and the monthly cost count from the database.
      CrawlRun.create!(source_kind:, stage: "crawl", status: "succeeded", finished_at: Time.current, stats: { USAGE => 1 })
      Rails.logger.info("[lead_finder] Brave search #{searches_today + 1}/#{SEARCHES_PER_DAY} today; " \
        "#{self.class.searches_in(Date.current)} this month")
      urls = (@search || method(:brave)).call("\"#{name}\" nuclear")
      urls.first(SEARCH_RESULTS).filter_map { |url| own_host(url) }.uniq
    end

    def searches_today = counted_today(USAGE)
    def counted_today(key) = CrawlRun.where(source_kind:, stage: "crawl", started_at: Time.current.all_day).where("stats ? '#{key}'").count

    def brave(query)
      uri = URI("#{SEARCH_API}?#{URI.encode_www_form(q: query, count: SEARCH_RESULTS, country: 'us')}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.get(uri.request_uri, { "X-Subscription-Token" => @search_key, "Accept" => "application/json",
          "User-Agent" => DataQuality::Fetcher::USER_AGENT })
      end
      return [] unless response.is_a?(Net::HTTPSuccess)

      Array(JSON.parse(response.body).dig("web", "results")).map { |result| result["url"].to_s }
    rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout
      []
    end

    def own_host(href)
      host = (URI.parse(href.to_s.strip).host.to_s.downcase rescue "")
      return if host.blank? || host.match?(NOT_OWN) || host.match?(NEWS_HOSTS)

      "https://#{host}"
    end

    # [:ok | :not_found | :not_named | :not_nuclear | :not_us, page, why]
    def verify(name, website)
      page = snapshot(website) or return [ :not_found, nil, "Couldn't read the site" ]
      text = visible_text(page)
      return [ :not_named, page, "The page doesn't name #{name}" ] unless text.downcase.include?(name.downcase)
      return [ :not_nuclear, page, "The page states no nuclear work" ] unless nuclear?(text, name)
      return [ :not_us, page, "The page shows no US address or 'United States'" ] unless text.match?(US)

      [ :ok, page, nil ]
    end

    # A page as a source of this kind, read through the shared Fetcher.
    def snapshot(url)
      source = Source.find_or_create_by!(url:) { |row| row.source_kind = source_kind }
      DataQuality::Snapshot.take(source, fetcher: @fetcher)
      source.reload
      source if source.crawl_ok? && source.content_text.present?
    end

    def propose(name, website, page, found)
      # A page another source kind already reads isn't re-titled for this one.
      return unconfirmed(name, website, "Its home page is already read for another source", found) unless page.source_kind == source_kind

      page.update!(title: name, extracted_sha256: nil)
      @pipeline.call(self)
      candidate = Candidate.where(source: page, kind: "organization").order(:id).last
      return unconfirmed(name, website, "The page has no sentence naming #{name} and its nuclear work", found) unless candidate

      outcome(:proposed, name:, website:, candidate_id: candidate.id, found:)
    end
end
