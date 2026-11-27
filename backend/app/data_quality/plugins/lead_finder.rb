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
  # Paid, no attribution credit (PM, 10 Nov).
  # Raised for the pending-company backlog (Tosin, 19 Nov): ~$8-10 a month at $5 per 1,000.
  SEARCHES_PER_DAY = 60
  USAGE = "brave_searches".freeze
  # A day Brave said its limit is reached: no more searches that day.
  STOPPED = "brave_stopped".freeze
  # Leads found a day, whatever asks (Infra, 10 Nov: a pasted long list can't spend the quotas).
  # Leads (Backend gates them at 50) plus the nightly pending-company sites (SITES_PER_NIGHT).
  FINDS_PER_DAY = 100
  FINDS = "finds".freeze
  # Extra same-site pages read for person-added leads, a day (Infra: a big batch can't spike the crawl).
  NUCLEAR_PAGES = "nuclear_pages".freeze
  NUCLEAR_PAGES_PER_DAY = 30
  LEAD_MARK = "#lead-finder".freeze
  # Brave's plan allows 1 request a second (Infra): this much between our calls.
  SEARCH_GAP = 1.1
  # Another run holding this kind's lock: waits and tries again, then :retry (not a try).
  BUSY_TRIES = 3
  BUSY_WAIT = 30
  SEARCH_RESULTS = 5
  NUCLEAR = DataQuality::Plugins::WirePress::STRONG_NUCLEAR
  # Is it a US company (DATA.md, "Is it a US company?"; #987): "United States", "U.S." (also before a space), a US ZIP,
  # "Charlotte, NC", "Idaho Falls, Idaho", or a headquarters in a US region ("will remain in the Bay Area").
  US_POSTAL = "A[LKZR]|C[AOT]|D[EC]|FL|GA|HI|I[ADLN]|K[SY]|LA|M[ADEINOST]|N[CDEHJMVY]|O[HKR]|PA|RI|S[CD]|T[NX]|UT|V[AT]|W[AIVY]".freeze
  US_STATES = %w[Alabama Alaska Arizona Arkansas California Colorado Connecticut Delaware Florida Georgia Hawaii Idaho Illinois
    Indiana Iowa Kansas Kentucky Louisiana Maine Maryland Massachusetts Michigan Minnesota Mississippi Missouri Montana Nebraska
    Nevada Ohio Oklahoma Oregon Pennsylvania Tennessee Texas Utah Vermont Virginia Washington Wisconsin Wyoming] +
    [ "New Hampshire", "New Jersey", "New Mexico", "New York", "North Carolina", "North Dakota", "Rhode Island", "South Carolina",
      "South Dakota", "West Virginia" ]
  US_CITY = "[A-Z][a-z]+(?:[ .'-]+[A-Z][a-z]+){0,3}".freeze
  US = /(?<![[:alnum:]])(?:United States|U\.S\.(?:A\.?)?|USA)(?![[:alnum:]])|\b(?:#{US_POSTAL})\s+\d{5}\b|\b#{US_CITY},\s+(?:#{US_POSTAL})\b|\b#{US_CITY},\s+(?:#{US_STATES.join('|')})\b/
  US_HQ_REGION = /headquarter\w*\b[^.]{0,80}?\b(?:the (?:San Francisco )?Bay Area|Silicon Valley|Washington,? D\.?C\.?)/i
  # A US listing counts only with US incorporation beside it: foreign companies list on Nasdaq too (DQ, 27 Nov).
  US_LISTING = /\b(?:Nasdaq|NYSE(?: American)?)\s*:\s*[A-Z]{1,5}\b/
  US_INCORPORATION = /\bInc\.?\s*[·|,–-]\s*Delaware\b|\ba Delaware (?:corporation|limited liability company|LLC)\b|\bincorporated in (?:the State of )?Delaware\b/i
  NEWS_HOSTS = /(?:\A|\.)(?:prnewswire|businesswire|globenewswire|accessnewswire|world-nuclear-news|ans|nucnet|neimagazine|utilitydive|reuters|bloomberg|yahoo)\.(?:com|org)\z/
  NOT_OWN = /(?:\A|\.)(?:linkedin|twitter|x|facebook|youtube|instagram|wikipedia|crunchbase|bloomberg|google|sec|prnewswire|cision)\.[a-z.]+\z/

  @@last_search = nil

  def self.call(lead_id, finder: new, input: nil) = finder.find(lead_id, input:)

  # Brave searches made in a month (each is a recorded crawl run), for PM's cost report:
  #   DataQuality::Plugins::LeadFinder.searches_in(Date.new(2026, 11))
  def self.searches_in(month) = CrawlRun.where(source_kind: "lead_finder", stage: "crawl")
    .where("stats ? '#{USAGE}'").where(started_at: month.beginning_of_month.all_month).count

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new, search: nil,
    search_key: ENV["BRAVE_SEARCH_API_KEY"], sleeper: ->(seconds) { sleep seconds }, pipeline: ->(plugin) { DataQuality::Pipeline.run("lead_finder", plugin:, only: %w[extract match]) })
    @fetcher, @directory, @search, @search_key, @pipeline, @sleeper = fetcher, directory, search, search_key, pipeline, sleeper
  end

  # Nothing to crawl on a schedule: each lead is found when asked.
  def crawl(_run) = {}

  # input: what Tosin typed (#752), read in place of the lead's name.
  # Leads a person put in (Tosin's Add a lead or list, DQ's Leads.md): their
  # company may be foreign with US nuclear operations (Cameco, Framatome,
  # Orano; PM, 11 Nov), so its home page needn't show a US address.
  PERSON_KEYS = /\A(?:admin:|list:|leads-md:)/

  # Pending companies created from a name alone (NRC, DOE, ARPA-E) have no
  # website, so Enrich can't read them for a category (DQ, 19 Nov: 50 of 50).
  # Each night up to SITES_PER_NIGHT of them get the same search and check as
  # a lead (named, nuclear, US), each at most once a week; a site that checks
  # out is proposed as their website claim (matched to them by name). The
  # finds and searches count toward the same daily limits.
  SITES_PER_NIGHT = 50
  SITE_FOR = "site_for".freeze

  def find_sites(limit: SITES_PER_NIGHT)
    tried = CrawlRun.where(source_kind:, stage: "crawl", started_at: 7.days.ago..).where("stats ? '#{SITE_FOR}'")
      .pluck(Arel.sql("(stats->>'#{SITE_FOR}')::bigint")).to_set
    # A pending company whose proposing claim DQ rejected is junk: never searched for (DQ, 19 Nov).
    rejected = Candidate.where(kind: "organization", subject_type: "Organization", dq_recommendation: "reject").pluck(:subject_id).to_set
    # Left out in the query, before the limit: hundreds of tried or rejected
    # pending companies would otherwise fill it and hide the verified ones.
    due = @directory.organizations_without_website(limit:, except: tried | rejected)
    due.to_h { |id, name| [ id, find_site(id, name) ] }
  end

  def find_site(id, name)
    return outcome(:retry, name:, reason: "Today's limit of #{FINDS_PER_DAY} finds is reached", found: {}) unless reserve(FINDS, FINDS_PER_DAY)

    # Already in the directory from a US official source (an NRC docket, a DOE
    # award), which shows its US operations: its own site needn't (DQ, 19 Nov:
    # Rolls-Royce SMR, Moltex, Candu, Blykalla).
    # A university's or national lab's home page, or a power buyer's, rarely
    # says nuclear: for those only, the page need only name it (Tosin, 20 Nov).
    @us_shown_elsewhere, @hints, found = true, "", { "name" => name }
    @power_buyer = power_buyer?(id, name)
    @search_failed = @search_capped = false
    @site_for_pending = true
    @release_links = []
    result = nil
    candidates_for(name, [], found).each do |website|
      # Another company's site is never this one's.
      next if @directory.organization(domain: URI(website).host)

      verdict, page, why = verify(name, website)
      (found["checked"] ||= []) << { "verdict" => verdict.to_s, "why" => why }.merge(found.key?("searched") ? {} : { "website" => website })
      next unless verdict == :ok

      # The claim is for this company itself, whatever name the page uses (Copilot).
      result = propose(name, website, page, found, organization_id: id)
      break
    end
    result ||= if (@search_failed || @search_capped) && !found["checked"]
      outcome(:retry, name:, reason: @search_capped ? "Today's search limit is reached; tried again next run" : "The search service was busy; tried again next run", found:)
    else
      unconfirmed(name, nil, "No website found", found)
    end
    # A week's rest only after a completed attempt: a blocked one comes back next run (Copilot).
    # What each search came to, for the misses breakdown (PM, 20 Nov): the
    # verdicts, with the host only for a site not from Brave (its terms: results are never kept).
    unless result.outcome == :retry
      checked = Array(found["checked"]).map { |check| { "host" => (URI(check["website"]).host if check["website"]), "verdict" => check["verdict"] }.compact }
      CrawlRun.create!(source_kind:, stage: "crawl", status: "succeeded", finished_at: Time.current,
        stats: { SITE_FOR => id, "site_outcome" => result.outcome.to_s, "searched" => found["searched"], "checked" => checked }.compact)
    end
    result
  end

  def find(lead_id, input: nil)
    lead = @directory.lead(lead_id) or raise ArgumentError, "No lead #{lead_id}"
    unless reserve(FINDS, FINDS_PER_DAY)
      # Not a try (Infra): the lead waits for tomorrow with its tries untouched.
      return outcome(:retry, name: input.presence || lead.name, reason: "Today's limit of #{FINDS_PER_DAY} finds is reached; tried again tomorrow", found: {})
    end
    lead = lead.with(name: input) if input.present?
    @power_buyer = @site_for_pending = false
    @us_shown_elsewhere = @person_added = lead.keys.to_a.any? { |key| key.match?(PERSON_KEYS) }
    # What a person said about it ("Austin microreactor startup"; Backend #806), for the search.
    @hints = Array(lead.respond_to?(:hints) ? lead.hints : nil).join(" ").squish.first(80)
    found = {}
    name, links = read_input(lead)
    # The company's own releases on a wire site, for its US status (DQ, 27 Nov).
    @release_links = links.select { |link| (URI.parse(link).host.to_s.downcase rescue "").match?(NEWS_HOSTS) }
    # A staging or preview link is never read, not even for the site's name (Copilot, #932).
    staging, links = links.partition { |link| staging_host?(link) }
    found["checked"] = staging.map { |link| { "verdict" => "staging", "why" => "#{URI(link).host} is a staging or preview host", "website" => link } } if staging.any?
    # A website alone: the name the site gives itself (its og:site_name, else its title's first part).
    name ||= site_name(links)
    found["name"] = name
    if name.blank?
      return unconfirmed(name, nil, found["checked"] ? "No company name to look for (#{checked_summary(found)})" : "No company name to look for", found)
    end

    if (known = @directory.organization(name:))
      return outcome(:duplicate, name:, organization_id: known.id, reason: "Already listed", found:)
    end

    candidates_for(name, links, found).each do |website|
      if (known = @directory.organization(domain: URI(website).host))
        return outcome(:duplicate, name:, website:, organization_id: known.id, reason: "Its website is already listed", found:)
      end
      verdict, page, why = verify(name, website)
      # A lead a person typed: the sentence may be on another page of its site (DQ, 20 Nov: Fluor's nuclear page).
      if @person_added && page && (verdict == :not_nuclear || (verdict == :ok && !nuclear_sentence?(page, name))) && (inner = nuclear_page(page, name))
        verdict, page, why = :ok, inner, nil
      end
      (found["checked"] ||= []) << { "verdict" => verdict.to_s, "why" => why }.merge(found.key?("searched") ? {} : { "website" => website })
      next unless verdict == :ok

      return propose(name, website, page, found)
    end
    # Today's searches used up, or Brave's limit hit: the lead waits for tomorrow, not one of its tries
    # (Backend, 10 Nov). "search limit" in the reason is what the health check counts (#821).
    return outcome(:retry, name:, reason: "Today's search limit is reached; tried again tomorrow", found:) if @search_capped && !found["checked"]
    return outcome(:retry, name:, reason: "The search service was busy; tried again later", found:) if @search_failed && !found["checked"]

    unconfirmed(name, nil, found["checked"] ? "No site checked out as this US nuclear company (#{checked_summary(found)})" : "No website found", found)
  end

  # The pending company, from the verified home page.
  def extract(source, _run)
    name = source.title.to_s.squish
    return [] if !source.url.end_with?(LEAD_MARK) || name.blank? || source.content_text.blank?

    # A site found for a company already listed (a pending one) is claimed for
    # that company by its own name, so Match can't give it to another (Copilot);
    # for a university, national lab or power buyer the sentence need only name it (Tosin, 20 Nov).
    target = (@directory.organization(id: source.enrich_organization_id) if source.enrich_organization_id)
    sentences = self_naming_sentences(source, name)
    quote = (sentences.find { |sentence| nuclear?(sentence, brand(name)) } || (sentences.first if target && (institution?(source.url.delete_suffix(LEAD_MARK)) || power_buyer?(target.id, target.name)))) or return []
    claimed = target ? target.name : page_name(quote.strip, name, site_names(source))
    [ { kind: "organization", quote: quote.strip, payload: { "name" => claimed, "website" => "https://#{URI(source.url).host}" } } ]
  end

  # The name as the company's own page writes it: the name as matched in
  # its quote, in the page's own capitals ("cameco" typed is "Cameco"), plus
  # following capitalised words only when the page's own title or site name
  # carries the longer phrase ("Fresh Fission America"). Never the text
  # someone typed (Backend, 18 Nov), never a heading's other words, a
  # possessive or a full stop (Copilot).
  def page_name(quote, name, site_names = [])
    matched = quote[/(?<![[:alnum:]])(?i:#{Regexp.escape(name.to_s.squish)})(?![[:alnum:]])/] ||
      quote[/(?<![[:alnum:]])(?i:#{Regexp.escape(brand(name))})(?![[:alnum:]])/] or return name
    after = quote[(quote.index(matched) + matched.length)..].to_s
    words = after.scan(/\A(?:\s+[A-Z][[:alnum:]&-]*)+/).first.to_s.split
    words.each_index.reverse_each do |count|
      longer = [ matched, *words.first(count + 1) ].join(" ")
      return longer if site_names.any? { |site| site.match?(/(?<![[:alnum:]])#{Regexp.escape(longer)}(?![[:alnum:]])/i) }
    end
    matched
  end

  # The page's own names for itself: its og:site_name and its title.
  def site_names(source)
    doc = Nokogiri::HTML(source.content_text)
    [ doc.at_css("meta[property='og:site_name']")&.[]("content"), doc.at_css("title")&.text ].compact.map(&:squish)
  end

  def source_facts(_source)
    "This is a company's own home page, read to confirm the company a lead names: its name, its website and that it " \
      "does nuclear work."
  end

  private
    # The name without its legal ending ("Fermi Inc." is "Fermi"), as a whole
    # word, so a page that writes the brand alone still names it (Infra, 18 Nov).
    LEGAL_ENDING = /[,\s]+(?:inc|llc|l\.l\.c|corp|corporation|co|company|ltd|limited|plc|lp)\.?\z/i
    def brand(name) = name.to_s.squish.sub(LEGAL_ENDING, "").presence || name.to_s

    # The full name as a whole word (any length: "GSE"), else the name
    # without its legal ending, when that's at least 4 letters (Copilot).
    def names?(text, name)
      whole = ->(wanted) { text.match?(/(?<![[:alnum:]])#{Regexp.escape(wanted)}(?![[:alnum:]])/i) }
      full = name.to_s.squish
      return true if full.present? && whole.(full)

      wanted = brand(name)
      wanted != full && wanted.length >= 4 && whole.(wanted)
    end

    # A home page with no address: its own contact or about page (at most two, robots and spacing as always) may show one.
    CONTACT = %r{contact|about|company|locations?|offices?|investors?}i
    def blocks(html) = Nokogiri::HTML(html.to_s).css("p, li, h1, h2, h3, h4").map { |node| node.xpath(".//text()").map(&:text).join(" ").squish }

    def naming_sentences(blocks, name) = blocks.flat_map { |block| block.split(/(?<=[.!?])\s+/) }.select { |sentence| names?(sentence, name) }

    def nuclear_sentence?(page, name) = self_naming_sentences(page, name).any? { |sentence| nuclear?(sentence, brand(name)) }

    # Sentences naming the company by its name or by the short name its own site uses for itself (#987: "FANCO is
    # not merely developing a reactor" on First American Nuclear's home page).
    def self_naming_sentences(page, name)
      found = blocks(page.content_text)
      ([ name ] + short_names(page, name)).flat_map { |each_name| naming_sentences(found, each_name) }.uniq
    end

    # "First American Nuclear (FANCO)" in the text, or the capitals of its header logo's file or alt ("FANCO-logo.svg"),
    # kept only when they start with the name's initials, so a partner's logo never counts.
    def short_names(page, name)
      initials = (brand(name).downcase.scan(/[[:alnum:]]+/) - NAME_FILLER).map { |word| word[0] }.join
      return [] if initials.length < 2

      doc = Nokogiri::HTML(page.content_text)
      found = visible_text(page).scan(/#{Regexp.escape(brand(name))}[^(]{0,12}\(([A-Z][A-Za-z]{1,9})\)/i).flatten
      found += doc.css("header img, nav img, a[href='/'] img").flat_map { |img| "#{File.basename(img['src'].to_s, '.*')} #{img['alt']}".scan(/\b[A-Z]{2,10}\b/) }
      found.uniq.select { |short| short.downcase.start_with?(initials) }
    end

    NUCLEAR_LINK = /nuclear|reactor|fission|\bsmr/i
    # Up to 3 pages of the same site whose link or address says nuclear, the
    # first with a sentence naming the company and its nuclear work.
    def nuclear_page(home, name)
      base = home.final_url.presence || home.url
      host = URI(base).host.to_s.downcase.delete_prefix("www.")
      links = Nokogiri::HTML(home.content_text).css("a[href]").filter_map do |link|
        url = URI.join(base, link["href"].to_s).to_s.split("#").first rescue next
        # The page already checked never takes one of the three places (Copilot).
        url if URI(url).host.to_s.downcase.delete_prefix("www.") == host && "#{URI(url).path} #{link.text}".match?(NUCLEAR_LINK) &&
          Source.bare_homepage(url) != Source.bare_homepage(base)
      end.uniq.first(3)
      links.each do |url|
        break unless reserve(NUCLEAR_PAGES, NUCLEAR_PAGES_PER_DAY)

        page = snapshot(url) or next
        return page if nuclear_sentence?(page, name)
      end
      nil
    rescue URI::Error
      nil
    end

    # The company's own pages show it's a US company (DATA.md, "Is it a US company?"): the home page, up to three of
    # its contact, about or investor pages, a second domain of the same brand it links to (terrestrialusa.com to
    # terrestrialenergy.com) with that domain's contact or about pages, and the company's own wire releases among
    # the lead's links. A listing counts with incorporation from any of them.
    def us_shown?(home, name)
      texts = [ visible_text(home) ]
      read = ->(page) { page && texts << visible_text(page) && us_text?(texts.join("\n")) }
      return true if us_text?(texts.first)
      return true if own_links(home, CONTACT, 3).any? { |url| read.(snapshot(url)) }

      if (other = brand_domain(home, name)) && (page = snapshot(other))
        return true if read.(page) || own_links(page, CONTACT, 2).any? { |url| read.(snapshot(url)) }
      end
      own_releases(name).any? { |release| read.(release) }
    end

    def us_text?(text) = text.match?(US) || text.match?(US_HQ_REGION) || (text.match?(US_LISTING) && text.match?(US_INCORPORATION))

    # Links on a page to the same site whose address or text matches, never the page itself (Copilot).
    def own_links(home, pattern, limit)
      base = home.final_url.presence || home.url
      host = URI(base).host.to_s.downcase.delete_prefix("www.")
      Nokogiri::HTML(home.content_text).css("a[href]").filter_map do |link|
        url = URI.join(base, link["href"].to_s).to_s.split("#").first rescue next
        uri = URI(url)
        url if uri.host.to_s.downcase.delete_prefix("www.") == host && "#{uri.path} #{link.text}".match?(pattern) &&
          Source.bare_homepage(url) != Source.bare_homepage(base)
      end.uniq.first(limit)
    rescue URI::Error
      []
    end

    # Another domain of the same brand that the company's own page links to (DQ, 27 Nov): its address carries the name.
    def brand_domain(home, name)
      base = home.final_url.presence || home.url
      host = URI(base).host.to_s.downcase.delete_prefix("www.")
      Nokogiri::HTML(home.content_text).css("a[href]").each do |link|
        uri = (URI.join(base, link["href"].to_s) rescue next)
        other = uri.host.to_s.downcase
        next unless uri.is_a?(URI::HTTPS) && other.present? && other.delete_prefix("www.") != host
        next if other.match?(NOT_OWN) || other.match?(NEWS_HOSTS) || staging_host?(uri.to_s) || !host_names?(uri.to_s, name)

        return "https://#{other}"
      end
      nil
    rescue URI::Error
      nil
    end

    # The company's own releases on a wire site among the lead's links (DQ, 27 Nov): only one whose
    # "About <Company>" section names it, never a partner's release that mentions it.
    def own_releases(name)
      Array(@release_links).first(2).filter_map do |url|
        page = snapshot(url) or next
        abouts = Nokogiri::HTML(page.content_text).css("p, h2, h3, h4, b, strong").filter_map { |node| node.text.squish[/\AAbout\s+([^:]{2,80}?)\s*:?\z/, 1] }
        page if abouts.any? { |about| names?(about, name) || names?(name, brand(about)) }
      end
    end

    # Each checked site's verdict, for the lead's note (Backend keeps only the
    # reason): "acme.com: not US; a search result: not named". A search
    # result's address is never kept (Brave's terms), only its verdict.
    VERDICTS = { "staging" => "staging host", "not_us" => "not US", "not_nuclear" => "no nuclear work", "not_named" => "not named", "not_found" => "unreadable" }.freeze
    def checked_summary(found)
      found["checked"].map do |check|
        site = check["website"] ? URI(check["website"]).host.to_s.delete_prefix("www.") : "a search result"
        "#{site}: #{VERDICTS.fetch(check['verdict'], check['verdict'])}"
      end.join("; ")
    end

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
      # A link alone, kept as its host and path ("nucube.energy"; CompanySuggestion.link_name): the site names it (#987).
      elsif name.match?(%r{\A[a-z0-9-]+(?:\.[a-z0-9-]+)+(?:/\S*)?\z}i) && links.any? { |link| link.downcase.include?(name.downcase.split("/").first) }
        name = nil
      end
      links.each do |link|
        slug = link[%r{linkedin\.com/company/([^/?#]+)}i, 1] and name ||= slug.tr("-_", " ").squish.titleize
      end
      [ name, links.reject { |link| link.match?(/linkedin\.com/i) } ]
    end

    # A website alone is named by the part of its title, og:site_name or header logo that its address carries
    # ("Home | NuCube Energy" on nucube.energy is "NuCube Energy"; #987), else its og:site_name, else its title's
    # first part that isn't "Home" or a page's own name.
    GENERIC_TITLE = /\A(?:home(?: ?page)?|about(?: us)?|welcome|contact(?: us)?|index)\z/i
    def site_name(links)
      news = links.find { |link| (URI.parse(link).host.to_s.downcase rescue "").match?(NEWS_HOSTS) }
      return about_name(news) if news

      site = links.filter_map { |link| own_host(link) }.first or return
      page = snapshot(site) or return
      doc = Nokogiri::HTML(page.content_text)
      site_name = doc.at_css("meta[property='og:site_name']")&.[]("content").to_s.squish.presence
      parts = doc.at_css("title")&.text.to_s.split(/\s+[|\u2013\u2014-]\s+|:\s+/).map(&:squish)
      logos = doc.css("header img[alt], nav img[alt]").map { |img| img["alt"].to_s.sub(/\s*logo\z/i, "").squish }
      fits = ->(part) { part.length.between?(2, 80) && !part.match?(GENERIC_TITLE) }
      address = page.final_url.presence || page.url
      ([ site_name ] + parts + logos).compact.find { |part| fits.(part) && host_names?(address, part) } ||
        (site_name if site_name && fits.(site_name)) || parts.find(&fits)
    end

    # A news page's single "About <Company>" heading names it.
    def about_name(url)
      page = snapshot(url) or return
      names = Nokogiri::HTML(page.content_text).css("p, h2, h3, h4, b, strong").filter_map { |node| node.text.squish[/\AAbout\s+([^:]{2,80}?)\s*:?\z/, 1] }.uniq
      names.first if names.one?
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
      sites.map { |site| university_home(site) }.uniq
    end

    # DOE's national labs' own domains (a .gov root).
    NATIONAL_LABS = %w[anl.gov bnl.gov fnal.gov inl.gov lanl.gov lbl.gov llnl.gov nrel.gov ornl.gov pnnl.gov sandia.gov
      srnl.gov netl.doe.gov ameslab.gov pppl.gov slac.stanford.edu jlab.org].freeze

    # Only a pending company's search, and only a university or national lab
    # (by the site's domain) or a power buyer (by its claims) (Tosin, 20 Nov).
    def nuclear_exempt?(website)
      @site_for_pending && (@power_buyer || institution?(website))
    end

    def institution?(website)
      host = URI(website).host.to_s.downcase.delete_prefix("www.")
      host.end_with?(".edu") || NATIONAL_LABS.include?(host)
    end

    # A claim naming it as the buyer in a power deal: offtake_with's from end,
    # offtakes_from a plant, or the power-buyer role; never a rejected one.
    def power_buyer?(id, name)
      claims = Candidate.where.not(status: "rejected").where(dq_recommendation: [ nil, "approve" ])
      claims.where(kind: "organization_role", subject_type: "Organization", subject_id: id).where("payload->>'role' = 'data_center_offtaker'")
        .or(claims.where(kind: "relationship").where("payload->>'relationship_type' = 'offtake_with' AND lower(payload->'from_organization'->>'name') = ?", name.downcase))
        .or(claims.where(kind: "facility_relationship").where("payload->>'relationship_type' = 'offtakes_from' AND lower(payload->'organization'->>'name') = ?", name.downcase))
        .exists?
    end

    # A lab's or program's .edu subdomain isn't the university's site: its home page is (DQ, 20 Nov).
    def university_home(site)
      host = (URI.parse(site).host.to_s rescue "")
      host.end_with?(".edu") && host.count(".") > 1 ? "https://#{host.split('.').last(2).join('.')}" : site
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
      # Brave said the month's limit or the spend cap is reached: no more searches today (Infra).
      if counted_today(STOPPED).positive?
        @search_capped = true
        return []
      end
      unless reserve(USAGE, SEARCHES_PER_DAY)
        @search_capped = true
        return []
      end

      Rails.logger.info("[lead_finder] Brave search #{counted_today(USAGE)}/#{SEARCHES_PER_DAY} today; " \
        "#{self.class.searches_in(Date.current)} this month")
      wait = @@last_search && (SEARCH_GAP - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @@last_search))
      @sleeper.call(wait) if wait&.positive?
      @@last_search = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      urls = (@search || method(:brave)).call([ "\"#{name}\"", @hints.presence, "nuclear" ].compact.join(" "))
      urls.first(SEARCH_RESULTS).filter_map { |url| own_host(url) }.uniq
    end

    # Takes one of today's places atomically (a transaction-scoped advisory lock), so two finders can't both take the last.
    # Each place is a recorded crawl run (never a search's results), so the cap and the monthly cost count from the database.
    def reserve(key, limit)
      CrawlRun.transaction do
        CrawlRun.connection.execute("SELECT pg_advisory_xact_lock(#{Zlib.crc32("lead_finder:#{key}")})")
        next false if counted_today(key) >= limit

        CrawlRun.create!(source_kind:, stage: "crawl", status: "succeeded", finished_at: Time.current, stats: { key => 1 })
      end.present?
    end
    def counted_today(key) = CrawlRun.where(source_kind:, stage: "crawl", started_at: Time.current.all_day).where("stats ? '#{key}'").count

    def brave(query)
      uri = URI("#{SEARCH_API}?#{URI.encode_www_form(q: query, count: SEARCH_RESULTS, country: 'us')}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.get(uri.request_uri, { "X-Subscription-Token" => @search_key, "Accept" => "application/json",
          "User-Agent" => DataQuality::Fetcher::USER_AGENT })
      end
      return brave_failed(response) unless response.is_a?(Net::HTTPSuccess)

      Array(JSON.parse(response.body).dig("web", "results")).map { |result| result["url"].to_s }
    rescue JSON::ParserError, Net::OpenTimeout, Net::ReadTimeout
      @search_failed = true
      []
    end

    # Any answer but a success (or a plain 404) is a failure, never "no
    # website": the lead is :retry, not a try. A 402/403 (spend cap, key) or
    # a 429 with the month used up stops searching for the rest of the day (Infra).
    def brave_failed(response)
      code = response.code.to_i
      return [] if code == 404

      @search_failed = true
      month_left = response["X-RateLimit-Remaining"].to_s.split(",").map(&:strip)[1]
      if [ 402, 403 ].include?(code) || (code == 429 && month_left == "0")
        # Recorded in the database, so a restart doesn't search again today (Copilot).
        CrawlRun.create!(source_kind:, stage: "crawl", status: "succeeded", finished_at: Time.current, stats: { STOPPED => code })
        @search_capped = true
        Rails.logger.warn("[lead_finder] Brave: monthly limit reached (HTTP #{code}); no more searches today")
      end
      []
    end

    def own_host(href)
      host = (URI.parse(href.to_s.strip).host.to_s.downcase rescue "")
      return if host.blank? || host.match?(NOT_OWN) || host.match?(NEWS_HOSTS)

      "https://#{host}"
    end

    # [:ok | :staging | :not_found | :not_named | :not_nuclear | :not_us, page, why]
    def verify(name, website)
      # A web agency's staging or preview copy is never the company's website (#932: WSC on public-stag.3keysoft.com).
      return [ :staging, nil, "#{URI(website).host} is a staging or preview host" ] if staging_host?(website)
      # (The Fetcher never follows a redirect to another host, so the page's own host is the one checked.)
      page = snapshot(website) or return [ :not_found, nil, "Couldn't read the site" ]
      text = visible_text(page)
      return [ :not_named, page, "The page doesn't name #{name}" ] unless names?(text, name)
      # The name, the nuclear work and the address must be the site owner's, not a
      # customer's in a testimonial (#932: Mainstream Engineering on calnanocorp.com).
      return [ :not_named, page, "The page names #{name} but isn't its own site" ] unless own_site?(page, name)
      return [ :not_nuclear, page, "The page states no nuclear work" ] unless nuclear_exempt?(website) || nuclear?(text, brand(name))
      unless @us_shown_elsewhere || us_shown?(page, name)
        return [ :not_us, page, "Neither its own pages nor its own releases show a US headquarters, office or address" ]
      end

      [ :ok, page, nil ]
    end

    # A subdomain word that marks a copy for testing or review ("staging.", "public-stag.", "dev2.").
    STAGING_WORDS = %w[stag stage staging dev develop development test testing qa uat preview sandbox].freeze
    # Only the labels before the registered domain count ("stage.co.uk" is a company's own domain; Copilot).
    def staging_host?(url)
      subdomain = PublicSuffix.parse(URI(url).host.to_s.downcase, ignore_private: true).trd.to_s
      subdomain.split(/[.-]/).any? { |word| STAGING_WORDS.include?(word.sub(/\d+\z/, "")) }
    rescue URI::Error, PublicSuffix::Error
      false
    end

    # The page is the company's own when its name is in the page's own name for
    # itself (title, og:site_name, the first h1, the header's logo) or its address.
    def own_site?(page, name)
      doc = Nokogiri::HTML(page.content_text)
      logos = doc.css("header img[alt], nav img[alt]").select { |img| "#{img['src']} #{img['class']} #{img['id']} #{img['alt']}".match?(/logo/i) }
      marks = site_names(page) + [ doc.at_css("h1")&.text.to_s.squish ] + logos.map { |img| img["alt"].squish }
      marks.any? { |mark| names?(mark, name) } || host_names?(page.final_url.presence || page.url, name)
    end

    # The address carries the name: "sawtoothsim.com" (its first word), "ws-corp.com" (the brand), "srnl.gov" (its initials).
    NAME_FILLER = %w[of and the for].freeze
    # A first word many names share never matches an address alone (DQ on #985): "Advanced" isn't advancedenergy.com's.
    GENERIC_FIRST = %w[university college institute advanced nuclear american national international global united general
      energy power atomic atomics home about welcome].freeze
    def host_names?(url, name)
      words = brand(name).downcase.scan(/[[:alnum:]]+/)
      return false if words.empty?

      whole = words.join
      initials = (words - NAME_FILLER).map { |word| word[0] }.join
      host = PublicSuffix.parse(URI(url).host.to_s.downcase, ignore_private: true)
      labels = [ host.trd, host.sld ].compact.join(".").delete_prefix("www.").split(".").map { |label| label.delete("^a-z0-9") }
      labels.any? do |label|
        (whole.length >= 3 && label.include?(whole)) || (words.first.length >= 4 && !GENERIC_FIRST.include?(words.first) && label.start_with?(words.first)) ||
          (initials.length >= 2 && label == initials) || (initials.length >= 3 && label.start_with?(initials))
      end
    rescue URI::Error, PublicSuffix::Error
      false
    end

    # A page as a source of this kind, read through the shared Fetcher.
    def snapshot(url)
      # Read as a plain web page, so Enrich (company_pages) can take it over later; only a verified copy is this kind's.
      source = Source.find_or_create_by!(url:) { |row| row.source_kind = "web_page" }
      DataQuality::Snapshot.take(source, fetcher: @fetcher)
      source.reload
      source if source.crawl_ok? && source.content_text.present?
    end

    def propose(name, website, page, found, organization_id: nil)
      # The verified home page, copied as this kind's own source (its URL marked): only
      # a page that passed verify is ever extracted here (Copilot).
      verified = Source.find_or_initialize_by(url: "#{page.final_url.presence || page.url}#{LEAD_MARK}")
      verified.update!(source_kind:, title: name, crawl_status: "ok", fetched_at: page.fetched_at, http_status: page.http_status,
        content_text: page.content_text, content_sha256: page.content_sha256, extracted_sha256: nil, enrich_organization_id: organization_id)
      BUSY_TRIES.times do |attempt|
        @pipeline.call(self)
        break
      rescue DataQuality::Pipeline::AlreadyRunning
        # A crawl's run holds the lock: wait, and in the end say "busy", which isn't one of the lead's tries (Infra).
        return outcome(:retry, name:, website:, reason: "Another run was busy; tried again later", found:) if attempt == BUSY_TRIES - 1

        @sleeper.call(BUSY_WAIT)
      end
      candidate = Candidate.where(source: verified, kind: "organization").order(:id).last
      return unconfirmed(name, website, "The page has no sentence naming #{name} and its nuclear work", found) unless candidate

      outcome(:proposed, name:, website:, candidate_id: candidate.id, found:)
    end
end
