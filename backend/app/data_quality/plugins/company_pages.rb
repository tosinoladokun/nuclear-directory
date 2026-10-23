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
  LINK = /about|company|who-we-are|mission|technolog|products?|solutions|reactor|contact|overview/i
  PROMPT_VERSION = "company_pages-1".freeze
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
    Never report people (founders, executives, staff), investors or customers from logo lists, plant status or capacity, numbers
    you computed, or anything about another company. A subsidiary's work isn't its parent's.
  TEXT

  def initialize(fetcher: DataQuality::Fetcher.new, llm: nil, directory: DataQuality::DirectoryClient.new)
    @fetcher, @llm, @directory = fetcher, llm, directory
  end

  def crawl(_run)
    stats = { "companies" => 0, "pages" => 0 }
    @directory.enrich_queue.each do |id, _name, website, requested_at|
      home = page(website) or next
      DataQuality::Snapshot.take(home, fetcher: @fetcher)
      stats["pages"] += 1
      own_links(home).first(PAGES).each do |url|
        DataQuality::Snapshot.take(page(url), fetcher: @fetcher)
        stats["pages"] += 1
      end
      @directory.mark_enriched(id, requested_at)
      stats["companies"] += 1
    end
    stats
  end

  def extract(source, run)
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
      { type: "object", additionalProperties: false, required: [ *FIELDS, "roles", "technologies" ],
        properties: FIELDS.index_with { quoted }.merge("roles" => keyed, "technologies" => keyed) }
    end
end
