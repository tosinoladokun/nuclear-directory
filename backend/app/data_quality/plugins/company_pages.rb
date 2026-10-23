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
  PROMPT_VERSION = "company_pages-2".freeze
  EXCHANGES = %w[NASDAQ NYSE NYSE\ American TSX TSXV LSE ASX OTC].freeze
  # Part 2 (#479): links in the directory's own verbs.
  COMPANY_VERBS = %w[supplies invests_in funds offtake_with subsidiary_of].freeze
  PLANT_VERBS = %w[owns operates vendor_for].freeze
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
    candidates(company.name, found, text)
  end

  private
    def llm = @llm ||= DataQuality::OpenRouter::Client.new

    # What a company's EDGAR record states, read as data (no model): its
    # legal name, its first listing, and its business address's city and
    # state. Each quote is the exact fragment of the stored record.
    def edgar_claims(source)
      cik = source.url[EDGAR_URL, 1]
      company = @directory.organization(sec_cik: cik) or return []
      text = source.content_text.to_s
      data = JSON.parse(text) rescue (return [])
      fragment = ->(pattern) { text[pattern] }
      claims = []
      if (name = data["name"].presence) && (quote = fragment.(/"name":\s*"#{Regexp.escape(name)}"/))
        claims << { kind: "organization", payload: { "name" => company.name, "legal_name" => name }, quote: }
      end
      ticker, exchange = Array(data["tickers"]).first, EDGAR_EXCHANGES[Array(data["exchanges"]).first]
      if ticker && exchange && (quote = fragment.(/"tickers":\s*\[[^\]]*\],\s*"exchanges":\s*\[[^\]]*\]/))
        claims << { kind: "organization", payload: { "name" => company.name, "exchange" => exchange, "ticker" => ticker }, quote: }
      end
      business = data.dig("addresses", "business") || {}
      city, state = business["city"].to_s.strip, business["stateOrCountry"].to_s.strip
      if city.present? && state.match?(/\A[A-Z]{2}\z/) && (quote = fragment.(/"business":\s*\{[^}]*\}/))
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
    def candidates(name, found, text)
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
      { "roles" => [ "organization_role", "role" ], "technologies" => [ "organization_technology", "technology" ] }.each do |list, (kind, key)|
        Array(found[list]).each do |item|
          next unless choices.fetch(key).include?(item["key"]) && quoted.(nil, item["quote"])

          fields << { kind:, payload: { "organization" => { "name" => name }, key => item["key"] }, quote: item["quote"].strip }
        end
      end
      fields
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
      { type: "object", additionalProperties: false, required: [ *FIELDS, "roles", "technologies", "listing", "links" ],
        properties: FIELDS.index_with { quoted }.merge("roles" => keyed, "technologies" => keyed, "listing" => listing, "links" => links) }
    end
end
