# Enrich (#479): a company's own pages, read on request (the admin's Enrich
# button), against a fixed list of fields. Crawl reads each requested
# company's home page and up to PAGES more of its own about, company,
# technology, products and contact pages. Extract asks the extract model
# for what each page states, with one verbatim quote per value, under Data
# Quality's rules (#479): a value that isn't in its quote, or a quote that
# isn't on the page, is dropped, never guessed. Every finding is an
# ordinary claim on that page: matched, verified and approved by a person.
# Part 1: description, HQ, founded year, legal name, roles, technologies.
class DataQuality::Plugins::CompanyPages < DataQuality::Plugin
  PAGES = 4
  EDGAR = "https://data.sec.gov/submissions/CIK%010d.json".freeze
  EDGAR_URL = %r{\Ahttps://data\.sec\.gov/submissions/CIK(\d{10})\.json\z}
  # EDGAR's exchange names, as the listing column has them.
  EDGAR_EXCHANGES = { "Nasdaq" => "NASDAQ", "NYSE" => "NYSE", "NYSE American" => "NYSE American", "OTC" => "OTC" }.freeze
  # US states: code => code, and name => code.
  STATES = %w[AL AK AZ AR CA CO CT DE FL GA HI ID IL IN IA KS KY LA ME MD MA MI MN MS MO MT NE NV NH NJ NM NY NC ND OH OK OR PA RI SC SD TN TX UT VT
    VA WA WV WI WY DC].to_h { |code| [ code, code ] }.freeze
  STATE_CODES = { "alabama" => "AL", "alaska" => "AK", "arizona" => "AZ", "arkansas" => "AR", "california" => "CA", "colorado" => "CO",
    "connecticut" => "CT", "delaware" => "DE", "florida" => "FL", "georgia" => "GA", "hawaii" => "HI", "idaho" => "ID", "illinois" => "IL",
    "indiana" => "IN", "iowa" => "IA", "kansas" => "KS", "kentucky" => "KY", "louisiana" => "LA", "maine" => "ME", "maryland" => "MD",
    "massachusetts" => "MA", "michigan" => "MI", "minnesota" => "MN", "mississippi" => "MS", "missouri" => "MO", "montana" => "MT",
    "nebraska" => "NE", "nevada" => "NV", "new hampshire" => "NH", "new jersey" => "NJ", "new mexico" => "NM", "new york" => "NY",
    "north carolina" => "NC", "north dakota" => "ND", "ohio" => "OH", "oklahoma" => "OK", "oregon" => "OR", "pennsylvania" => "PA",
    "rhode island" => "RI", "south carolina" => "SC", "south dakota" => "SD", "tennessee" => "TN", "texas" => "TX", "utah" => "UT",
    "vermont" => "VT", "virginia" => "VA", "washington" => "WA", "west virginia" => "WV", "wisconsin" => "WI", "wyoming" => "WY",
    "district of columbia" => "DC" }.freeze
  # The company's own pages worth reading, by their address or link text.
  LINK = /about|company|who-we-are|mission|technolog|products?|solutions|reactor|contact|overview|investors?|partners?|projects?/i
  PROMPT_VERSION = "company_pages-4".freeze
  EXCHANGES = %w[NASDAQ NYSE NYSE\ American TSX TSXV LSE ASX OTC].freeze
  # Part 2 (#479): links in the directory's own verbs.
  COMPANY_VERBS = %w[supplies invests_in funds offtake_with subsidiary_of].freeze
  PLANT_VERBS = %w[owns operates vendor_for].freeze
  # A link is what is so now, never a plan.
  PLANNED = /\b(plans? to|planning to|aims? to|will|intends? to|in talks|exploring|considering)\b/i
  # A round the company says it has, not one it seeks.
  RAISED = /\b(raised|raises|closed|closes|secured|secures|completed)\b/i
  # The form of agreement, from the quote's own words (#439's list); the
  # first that matches, early stages first so an "MOU for a PPA" stays an MOU.
  AGREEMENT_WORDS = {
    "mou" => /\b(memorandum of understanding|MOU)\b/i, "loi" => /\b(letter of intent|LOI)\b/i,
    "framework" => /\bframework\b/i, "option" => /\boption\b/i, "preorder" => /\bpre-?order\b/i,
    "development_agreement" => /\bdevelopment agreement\b/i, "prepayment" => /\bprepay(ment)?\b/i,
    "ppa" => /\b(power purchase agreement|PPA)\b/i, "supply_agreement" => /\bsupply (agreement|contract)\b/i,
    "tariff_subscription" => /\btariff\b/i
  }.freeze
  # A round, not a grant, award, loan or contract; an exact figure only.
  ROUND_WORDS = /\b(round|funding|financing|series\s+[a-z]\b|seed|investment|(raised|raise|raises)\s+(equity|capital))/i
  NOT_A_ROUND = /\b(awards?|grants?|contracts?|loans?|debt|credit\s+facility|PPA|power\s+purchase)\b/i
  INEXACT = /\b(up\s+to|more\s+than|over|about|approximately|nearly|at\s+least|total|totals|totaling|totalling)\b/i
  # An owner's quote says it owns.
  OWNERSHIP = /\b(own|owns|owned|owner|ownership|stake|share)\b|\d+(\.\d+)?\s?%/i
  FIELDS = %w[description hq_city hq_state founded_year legal_name].freeze

  INSTRUCTIONS = <<~TEXT.freeze
    You read one page of a company's own website and report only what the page itself states about that company, for a nuclear
    industry directory. Fill a field only when the page states it plainly; otherwise leave it null or empty.
    Every value needs a quote: a sentence or phrase copied exactly from the page, and the value must appear in that quote.
    Fields:
    - description: one neutral sentence of what the company does, copied from the page (no adjectives like leading or world-class;
      leave it null if the page only has marketing language).
    - hq_city and hq_state: where its headquarters are, only if the page says headquarters. An office is not headquarters unless the page says so.
    - founded_year: only if the quote contains the year it was founded.
    - legal_name: only an exact legal name with its suffix (Inc., LLC, Corp.), as written.
    - roles: what the company does, from the role keys given; never from "plans to", "aims to" or "will".
    - technologies: what it works on, from the technology keys given.
    For roles and technologies the quote itself must state the activity in a sentence: a menu heading, a navigation label or a list
    of links is not enough.
    If the page is about another company (a partner, parent, customer, or a press item about someone else), report nothing.
    - listing: a public company's stock listing (exchange and ticker, e.g. NASDAQ and OKLO), only as the page states it.
    - links: another company or a plant this company has a stated relationship with. The quote must name both this company (or
      "we") and the other party, and state the relationship in a sentence. Verbs: supplies, invests_in, funds, offtake_with
      (buys or sells power under an agreement), subsidiary_of (only when the page says it is a subsidiary or wholly owned), and for
      plants owns, operates, vendor_for (it designed the plant's reactor). company_first is true when this company does the verb to
      the other ("we supply X"), false when the other does it to this company ("X invested in us"). No amounts or dates here.
      Never a link from "plans to", "aims to", "will", "intends to", "in talks" or "exploring": only what is so now.
      An MOU, framework, letter of intent, option, term sheet or non-binding agreement is never a signed deal: report it only when
      the quote itself says which it is, so that word stays with it.
      owns needs an ownership statement ("owns", "owned by", a stake or share); hosting a site or campus is not owning the plant.
    - rounds: this company's own funding rounds the page says it raised or closed (not one it plans or seeks). amount: the amount
      exactly as the quote writes it ("$37 million"), or null; round: its name as written ("Series B", "seed"), or null; date: the
      date exactly as the quote writes it ("December 6, 2024"), or null. The quote must name this company (or "we") and the round.
      Not grants, awards, loans, debt or contracts; not a round of another company; amounts exactly as written, never summed.
      Never investors' names, valuations or totals across rounds.
    - deals: an agreement this company has with another company to buy or sell power or fuel (offtake or supply). other: the other
      company as named; company_first: true when this company sells or supplies to the other; amount and capacity exactly as the
      quote writes them ("$80 million", "500 MW"), or null; date as written, or null. The quote must name both parties (or "we"),
      say what kind of agreement it is (power purchase agreement, supply agreement, MOU, letter of intent, framework, option…),
      and state it as signed or in force, never planned.
    Never report people (founders, executives, staff), investors or customers from logo lists, plant status or capacity, numbers
    you computed, or anything about another company. A subsidiary's work isn't its parent's.
  TEXT

  def initialize(fetcher: DataQuality::Fetcher.new, llm: nil, directory: DataQuality::DirectoryClient.new)
    @fetcher, @llm, @directory = fetcher, llm, directory
  end

  def crawl(_run)
    stats = { "companies" => 0, "pages" => 0 }
    @directory.enrich_queue.each do |id, _name, website, requested_at, sec_cik|
      # Part 3: a public company's SEC record (EDGAR), the primary source for
      # its legal name, listing and headquarters address (Data Quality).
      if sec_cik.present? && (edgar = page(format(EDGAR, sec_cik.to_i)))
        DataQuality::Snapshot.take(edgar, fetcher: @fetcher)
        stats["pages"] += 1
      end
      # A home page that couldn't be read is answered as read (the Enrich page
      # shows why, from the page's own status), and a new request reads again.
      if (home = page(website))
        DataQuality::Snapshot.take(home, fetcher: @fetcher)
        stats["pages"] += 1
        own_links(home).first(PAGES).each do |url|
          DataQuality::Snapshot.take(page(url), fetcher: @fetcher)
          stats["pages"] += 1
        end
      end
      @directory.mark_enriched(id, requested_at)
      stats["companies"] += 1
    end
    stats
  end

  def extract(source, run)
    return edgar_claims(source) if source.url.match?(EDGAR_URL)

    company = @directory.organization(domain: source.domain) or return []
    text = visible_text(source)
    return [] if text.blank?

    run&.update!(prompt_version: PROMPT_VERSION)
    found = llm.structured(role: :extract, schema:, schema_name: "company_pages", crawl_run: run, reasoning_effort: "low",
      messages: [ { role: "system", content: INSTRUCTIONS }, { role: "user", content: prompt(company.name, text) } ]).data
    candidates(company.name, found, text, url: source.url)
  end

  private
    def llm = @llm ||= DataQuality::OpenRouter::Client.new

    # What a company's EDGAR record states, read as data (no model): its
    # single listing and its business address's city and
    # state. Each quote is the exact fragment of the stored record.
    def edgar_claims(source)
      cik = source.url[EDGAR_URL, 1]
      company = @directory.organization(sec_cik: cik) or return []
      text = source.content_text.to_s
      data = JSON.parse(text) rescue (return [])
      fragment = ->(pattern) { text[pattern] }
      claims = []
      # EDGAR's name is upper case and sometimes shortened, so it's never a
      # legal name (Data Quality). Several tickers (share classes) are skipped.
      tickers, exchanges = Array(data["tickers"]), Array(data["exchanges"])
      ticker, exchange = tickers.first, EDGAR_EXCHANGES[exchanges.first]
      if tickers.size == 1 && exchanges.size == 1 && ticker && exchange && (quote = fragment.(/"tickers":\s*\[[^\]]*\],\s*"exchanges":\s*\[[^\]]*\]/))
        claims << { kind: "organization", payload: { "name" => company.name, "exchange" => exchange, "ticker" => ticker }, quote: }
      end
      business = data.dig("addresses", "business") || {}
      city, state = business["city"].to_s.strip, business["stateOrCountry"].to_s.strip
      street = "#{business['street1']} #{business['street2']}"
      # Only a US state (EDGAR codes other places A1, X1…), never a PO box.
      if city.present? && STATES.key?(state) && !street.match?(/\bP\.?\s*O\.?\s*Box\b/i) && (quote = fragment.(/"business":\s*\{[^}]*\}/))
        claims << { kind: "organization", payload: { "name" => company.name, "hq_city" => city.titleize, "hq_state" => state }, quote: }
      end
      claims
    end

    # A page of this kind, made or taken over from a page cited by hand.
    def page(url)
      url = url.to_s.strip
      return unless url.match?(%r{\Ahttps?://}i)

      source = Source.find_or_create_by!(url:) { |new_page| new_page.source_kind = source_kind }
      source.update!(source_kind:) if source.source_kind == "web_page"
      source
    end

    # Links on the home page to the company's own pages worth reading.
    def own_links(home)
      return [] unless home.crawl_ok? && home.content_text.present?

      host = URI(home.url).host.to_s.downcase.delete_prefix("www.")
      Nokogiri::HTML(home.content_text).css("a[href]").filter_map do |link|
        url = URI.join(home.url, link["href"]).to_s.split("#").first rescue next
        uri = URI(url)
        url if uri.host.to_s.downcase.delete_prefix("www.") == host && uri.scheme == "https" && url != home.url && "#{uri.path} #{link.text}".match?(LINK)
      end.uniq
    end

    def prompt(name, text)
      choices = @directory.company_fact_choices
      "Company: #{name}\nRole keys: #{choices['role'].map(&:first).join(', ')}\n" \
        "Technology keys: #{choices['technology'].map(&:first).join(', ')}\n\nPage text:\n#{text.first(12_000)}"
    end

    # Only what's in its quote, with a quote on the page; keys from the lists.
    def candidates(name, found, text, url: nil)
      page = text.downcase.squish
      quoted = ->(value, quote) { quote.present? && page.include?(quote.downcase.squish) && (value.nil? || quote.downcase.include?(value.to_s.downcase)) }
      choices = @directory.company_fact_choices.transform_values { |pairs| pairs.map(&:first) }
      fields = FIELDS.filter_map do |field|
        value, quote = found.dig(field, "value"), found.dig(field, "quote")
        # Every value inside its own quote, a description included (Data Quality).
        next if value.blank? || !quoted.(value, quote)

        value = value.to_s.strip
        # The directory keeps a state as its two-letter code ("Texas" in the quote is TX).
        value = (STATES[value.upcase] || STATE_CODES[value.downcase] or next) if field == "hq_state"
        { kind: "organization", payload: { "name" => name, field => value }, quote: quote.strip }
      end
      listing = found["listing"]
      if listing && EXCHANGES.include?(listing["exchange"]) && listing["ticker"].to_s.match?(/\A[A-Z.]{1,6}\z/) &&
          quoted.(listing["ticker"], listing["quote"])
        fields << { kind: "organization", payload: { "name" => name, "exchange" => listing["exchange"], "ticker" => listing["ticker"] },
          quote: listing["quote"].strip }
      end
      Array(found["links"]).each do |link|
        other, verb, quote = link["other"].to_s.strip, link["verb"], link["quote"]
        next if other.blank? || !quoted.(other, quote)
        # The quote names both parties (this company, or "we"), states what is
        # so now, and an owner's quote says it owns (Data Quality's rules).
        next unless quote.downcase.include?(name.downcase) || quote.match?(/\b(we|our|us)\b/i)
        next if quote.match?(PLANNED)
        next if verb == "owns" && !quote.match?(OWNERSHIP)

        if link["other_is"] == "plant"
          next unless PLANT_VERBS.include?(verb)

          fields << { kind: "facility_relationship", quote: quote.strip,
            payload: { "organization" => { "name" => name }, "facility" => { "name" => other }, "relationship_type" => verb } }
        else
          next unless COMPANY_VERBS.include?(verb)

          ends = [ { "name" => name }, { "name" => other } ]
          ends.reverse! unless link["company_first"]
          fields << { kind: "relationship", quote: quote.strip,
            payload: { "from_organization" => ends.first, "to_organization" => ends.last, "relationship_type" => verb } }
        end
      end
      Array(found["deals"]).each do |item|
        deal = two_party_deal(name, item, quoted, url) and fields << deal
      end
      Array(found["rounds"]).each do |item|
        round = funding_round(name, item, quoted, url) and fields << round
      end
      { "roles" => [ "organization_role", "role" ], "technologies" => [ "organization_technology", "technology" ] }.each do |list, (kind, key)|
        Array(found[list]).each do |item|
          next unless choices.fetch(key).include?(item["key"]) && quoted.(nil, item["quote"])

          fields << { kind:, payload: { "organization" => { "name" => name }, key => item["key"] }, quote: item["quote"].strip }
        end
      end
      fields
    end

    # A round the company states it raised, as a deal term (#401's kind) on
    # the company itself: "announced", since only one party states it (Data
    # Quality's two-party rule). Every value is in the quote; the ID keeps a
    # re-read of the page on the same row.
    def funding_round(name, item, quoted, url)
      quote = item["quote"].to_s.strip
      amount_text, round, date_text = item.values_at("amount", "round", "date").map { |value| value.to_s.strip.presence }
      return unless quoted.(nil, quote) && (quote.downcase.include?(name.downcase) || quote.match?(/\b(we|our|us)\b/i))
      return if quote.match?(PLANNED) || !quote.match?(RAISED) || !quote.match?(ROUND_WORDS) || quote.match?(NOT_A_ROUND) || quote.match?(INEXACT)
      return if [ amount_text, round, date_text ].compact.any? { |value| !quote.downcase.include?(value.downcase) }

      amount = dollars(amount_text) if amount_text
      return if amount_text && !amount
      return unless amount || round

      # A page's date is when it was announced; it's the round's date only when
      # the quote says the round closed on it (Data Quality).
      on_close = date_text && quote.match?(/\bon\s+#{Regexp.escape(date_text)}\b/i) && quote.match?(/\b(closed|completed)\b/i)
      starts_on = (Date.parse(date_text) if on_close && date_text.match?(/\b(19|20)\d\d\b/)) rescue nil
      { kind: "deal_term", quote:, payload: {
        "organization" => { "name" => name }, "link_type" => "Organization", "term_type" => "funding_round", "status" => "announced",
        "external_id" => "page:#{url}##{[ round, amount_text ].compact.join(' ').downcase.squish}", "amount_usd" => amount&.to_s("F"), "round" => round,
        "starts_on" => starts_on&.iso8601 }.compact }
    end

    # A deal between this company and another (#256), as a deal term on
    # their link: "announced", since only this company states it (Data
    # Quality's two-party rule). The form of agreement is read from the
    # quote's own words; every value is in the quote.
    def two_party_deal(name, item, quoted, url)
      other, quote = item["other"].to_s.strip, item["quote"].to_s.strip
      return if other.blank? || !quoted.(other, quote)
      return unless quote.downcase.include?(name.downcase) || quote.match?(/\b(we|our|us)\b/i)
      return if quote.match?(PLANNED) || quote.match?(INEXACT)

      agreement = AGREEMENT_WORDS.find { |_key, words| quote.match?(words) }&.first or return
      amount_text, capacity_text, date_text = item.values_at("amount", "capacity", "date").map { |value| value.to_s.strip.presence }
      return if [ amount_text, capacity_text, date_text ].compact.any? { |value| !quote.downcase.include?(value.downcase) }

      amount = dollars(amount_text) if amount_text
      capacity = megawatts(capacity_text) if capacity_text
      return if (amount_text && !amount) || (capacity_text && !capacity)

      signed_on = (Date.parse(date_text) if date_text&.match?(/\b(19|20)\d\d\b/) && quote.match?(/\bsign(ed|s)?\b/i)) rescue nil
      ends = [ { "name" => name }, { "name" => other } ]
      ends.reverse! unless item["company_first"]
      { kind: "deal_term", quote:, payload: {
        "link_type" => "Relationship", "from_organization" => ends.first, "to_organization" => ends.last, "relationship_type" => (agreement == "supply_agreement" ? "supplies" : "offtake_with"),
        "term_type" => "offtake", "agreement" => agreement, "status" => "announced",
        "external_id" => "page:#{url}##{[ other, agreement, amount_text, capacity_text ].compact.join(' ').downcase.squish}",
        "amount_usd" => amount&.to_s("F"), "capacity_mw" => capacity&.to_s("F"), "signed_on" => signed_on&.iso8601 }.compact }
    end

    # "500 MW", "1.2 GW" as megawatts; nil otherwise.
    def megawatts(text)
      match = text.match(/\A([\d,]+(?:\.\d+)?)\s*(MW|GW|megawatts?|gigawatts?)\z/i) or return
      number = BigDecimal(match[1].delete(","))
      match[2].downcase.start_with?("g") ? number * 1000 : number
    end

    # "$37 million", "$1.2 billion", "$37,000,000" as dollars; nil otherwise.
    def dollars(text)
      match = text.match(/\A(?:US)?\$\s?([\d,]+(?:\.\d+)?)\s*(million|billion|m|bn|b)?\z/i) or return
      number = BigDecimal(match[1].delete(","))
      number * { "million" => 1e6, "m" => 1e6, "billion" => 1e9, "bn" => 1e9, "b" => 1e9 }.fetch(match[2].to_s.downcase, 1).to_i
    end

    def schema
      quoted = { type: %w[object null], additionalProperties: false, required: %w[value quote],
        properties: { value: { type: "string" }, quote: { type: "string" } } }
      keyed = { type: "array", items: { type: "object", additionalProperties: false, required: %w[key quote],
        properties: { key: { type: "string" }, quote: { type: "string" } } } }
      listing = { type: %w[object null], additionalProperties: false, required: %w[exchange ticker quote],
        properties: { exchange: { type: "string" }, ticker: { type: "string" }, quote: { type: "string" } } }
      links = { type: "array", items: { type: "object", additionalProperties: false, required: %w[other other_is verb company_first quote],
        properties: { other: { type: "string" }, other_is: { type: "string", enum: %w[company plant] },
          verb: { type: "string", enum: COMPANY_VERBS + PLANT_VERBS }, company_first: { type: "boolean" }, quote: { type: "string" } } } }
      maybe = { type: %w[string null] }
      deals = { type: "array", items: { type: "object", additionalProperties: false,
        required: %w[other company_first amount capacity date quote],
        properties: { other: { type: "string" }, company_first: { type: "boolean" }, amount: maybe, capacity: maybe, date: maybe,
          quote: { type: "string" } } } }
      rounds = { type: "array", items: { type: "object", additionalProperties: false, required: %w[amount round date quote],
        properties: { amount: maybe, round: maybe, date: maybe, quote: { type: "string" } } } }
      { type: "object", additionalProperties: false, required: [ *FIELDS, "roles", "technologies", "listing", "links", "rounds", "deals" ],
        properties: FIELDS.index_with { quoted }.merge("roles" => keyed, "technologies" => keyed, "listing" => listing, "links" => links,
          "rounds" => rounds, "deals" => deals) }
    end
end
