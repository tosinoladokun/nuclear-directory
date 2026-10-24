# NRC's licensed fuel cycle facilities (#386), for Fuel and materials:
# enrichment, conversion, deconversion and fuel fabrication plants, from
# NRC's fuel cycle facility locations page and each facility's own page.
#
# Crawl fetches the locations page, then each facility page it links, each
# at most once a day through the shared Fetcher, and stores only the
# facility's labelled facts (name, location, licensee, docket, type,
# status), never the page's contacts. A block stops the crawl; a page
# without its facts goes to a person.
#
# Extract proposes the facility (enrichment for an enrichment plant, else
# fuel_facility; city and state from Location; NRC docket) and its licensee.
# Only for an operational facility does it add the licensee's operates link
# and the fuel stage its type states (enrichment, conversion or
# fabrication): a licence alone doesn't say a plant runs (DQ, 22 Oct, on
# #411). No capacity, no model. Match, verify and approval are shared.
class DataQuality::Plugins::NrcFuelCycle < DataQuality::Plugin
  include DataQuality::UnlistedPages

  NRC = "https://www.nrc.gov".freeze
  LIST_URL = "https://www.nrc.gov/facilities-safety/facility-finder/fc".freeze
  PAGE_PATH = %r{\A/facilities-safety/facility-finder/fc/(?!project-managers)[a-z0-9-]+}
  LABELS = [ "Location", "Licensee", "Docket Number", "Facility Type", "Facility Status" ].freeze
  NO_FACTS = "The facility's page is missing one of #{LABELS.join(', ')}; the page layout may have changed"
  UNLISTED = "NRC's fuel cycle locations page no longer links this facility"
  LISTED_AGAIN = "NRC's fuel cycle locations page links this facility again"
  NO_LINKS = "The locations page links no facility pages; the page layout may have changed"
  # The type's words => the fuel stage it states.
  STAGES = { /\bEnrichment\b/i => "enrichment", /\bConversion\b/i => "conversion", /\bFabrication\b/i => "fabrication" }.freeze
  STATE_CODES = LinkCard::US_STATES.invert.merge(LinkCard::US_STATES.keys.to_h { |code| [ code, code ] }).freeze

  Plant = Data.define(:name, :facts) do
    def line = [ name, *LABELS.filter_map { |label| "#{label}: #{facts[label]}" if facts[label] } ].join(" | ")
    def operational? = facts["Facility Status"].to_s.match?(/\AOperational\b/i)
    def stage = STAGES.find { |pattern, _| facts["Facility Type"].to_s.match?(pattern) }&.last
    def facility_type = facts["Facility Type"].to_s.match?(/\bEnrichment\b/i) ? "enrichment" : "fuel_facility"
    def city = facts["Location"].to_s[/\A([^,]+),/, 1]&.strip
    def state = STATE_CODES[facts["Location"].to_s[/,\s*([A-Za-z ]+)\z/, 1].to_s.strip]
  end

  # A facility page with nothing to store.
  class Unreadable < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(run)
    list = Source.find_or_create_by!(url: LIST_URL) do |row|
      row.source_kind = INDEX_SOURCE_KIND
      row.title = "NRC: locations of fuel cycle facilities"
    end
    stats = { "list" => DataQuality::Snapshot.take(list, fetcher: @fetcher).to_s }
    return stats.merge("stopped" => "list page blocked") if stats["list"] == "blocked"
    return stats unless list.crawl_ok? && list.content_text.present?

    paths = paths(list.content_text)
    if paths.empty?
      list.update!(crawl_status: "needs_human", status_reason: NO_LINKS)
      return stats.merge("facility_pages" => 0)
    end
    urls = paths.map { |path| "#{NRC}#{path}" }
    stats["withdrawn"] = withdraw_unlisted(urls, run, UNLISTED)
    stats["facility_pages"] = Hash.new(0)
    urls.each do |url|
      result = read(url)
      stats["facility_pages"][result] += 1
      # A block recorded earlier today stops a same-day rerun too, before any later page.
      return stats.merge("stopped" => "facility page blocked") if result == "blocked" || still_blocked?(Source.find_by!(url:))

      restored = restore_listed(Source.find_by!(url:), LISTED_AGAIN)
      stats["restored"] = stats.fetch("restored", 0) + restored if restored.positive?
    end
    stats.reject { |key, value| key == "withdrawn" && value.zero? }
  end

  # The locations page is only an index, never extracted.
  INDEX_SOURCE_KIND = "nrc_fuel_cycle_index"

  def extract(source, _run)
    facility = parse(source.content_text) or return []

    site = { "name" => facility.name, "facility_type" => facility.facility_type, "nrc_docket" => facility.facts["Docket Number"],
      "country_code" => "US", "city" => facility.city, "state" => facility.state }.compact
    licensee = { "name" => facility.facts["Licensee"] }
    claims = [ { kind: "facility", quote: facility.line, payload: site }, { kind: "organization", quote: facility.line, payload: licensee } ]
    return claims unless facility.operational?

    claims << { kind: "facility_relationship", quote: facility.line, payload: { "organization" => licensee,
      "facility" => { "name" => facility.name, "nrc_docket" => facility.facts["Docket Number"] }, "relationship_type" => "operates" } }
    claims << { kind: "organization_role", quote: facility.line, payload: { "organization" => licensee, "role" => facility.stage } } if facility.stage
    claims
  end

  # One facility per page: anything it stops stating goes to a person.
  # Pages never read before, at most 10 facility pages a night (about 40 claims), so Data Quality reads
  # each night's batch claim by claim (#541); pages read before are never held back.
  def new_sources_per_run = 10

  def max_dropped_share(_source) = 1.0

  def quote_in_source?(source, quote) = source.content_text.to_s == quote.to_s

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is the U.S. Nuclear Regulatory Commission's page for one licensed fuel cycle facility in the United " \
      "States (country code US): its name, location, the company holding its NRC license (Licensee), NRC docket, the " \
      "type of facility and whether it's operational."
  end

  private
    def paths(html)
      Nokogiri::HTML(html.to_s).css("a[href]").filter_map { |a| a["href"][PAGE_PATH] }.uniq
    end

    def read(url)
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = "NRC fuel cycle facility"
      end
      take_over(source)
      return "another_kind" unless source.source_kind == source_kind

      DataQuality::Snapshot.take(source, fetcher: @fetcher) { |html| stored_line(html) }.to_s
    rescue Unreadable
      source.update!(crawl_status: "needs_human", status_reason: NO_FACTS)
      "needs_human"
    end

    # The facility's name and labelled facts, never the page's people.
    def stored_line(html)
      doc = Nokogiri::HTML(html.to_s)
      name = doc.at_css("main h1, h1")&.text.to_s.squish
      facts = LABELS.to_h { |label| [ label, value_after(doc, label) ] }.compact
      raise Unreadable if name.empty? || LABELS.any? { |label| facts[label].blank? }

      Plant.new(name:, facts:).line
    end

    def value_after(doc, label)
      strong = doc.css("strong").find { |node| node.text.gsub(/[[:space:]]+/, " ").strip.delete_suffix(":").strip == label } or return
      text = +""
      node = strong.next_sibling
      while node && node.name != "br" && node.name != "strong"
        text << node.text
        node = node.next_sibling
      end
      text.gsub(/[[:space:]]+/, " ").strip.presence
    end

    def parse(text)
      name, *rest = text.to_s.split(" | ")
      facts = rest.to_h { |part| part.split(": ", 2) }
      return if name.blank? || !(LABELS & facts.keys).include?("Docket Number") || facts.keys.any? { |key| !LABELS.include?(key) }

      Plant.new(name:, facts:)
    end
end
