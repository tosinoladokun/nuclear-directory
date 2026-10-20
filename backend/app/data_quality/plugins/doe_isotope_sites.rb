# The DOE Isotope Program's production sites (#276, part 1), for the
# isotopes tag: the national labs and universities DOE names on its
# "DOE IRP Production Sites" page at isotopes.gov.
#
# Crawl fetches that one page, once a day, through the shared Fetcher. A
# block is recorded and stops the crawl; a page without its two paragraphs
# (labs, then universities) is marked needs_human.
#
# Extract reads names from the page's own sentences, never from memory: a
# lab named as "<Name> National Laboratory (ABBR)" (or Y-12's "National
# Security Complex") in a sentence about producing or processing isotopes,
# and each school in the sentence listing DOE's University Isotope Network.
# Each one gives a company (its abbreviation as an alias), the isotopes
# category and, where its own name says so, national_lab or university,
# quoting the sentence that names it. A university's network membership
# doesn't by itself say it produces isotopes, so verify holds its isotopes
# claim for a person (hold_for_review), after match has attached it. No
# model is asked. Match, verify and approval are shared.
class DataQuality::Plugins::DoeIsotopeSites < DataQuality::Plugin
  PAGE_URL = "https://www.isotopes.gov/production-network"
  LAYOUT_CHANGED = "Couldn't find the production sites' sentences; the page layout may have changed"
  # "Brookhaven National Laboratory (BNL)", "Y-12 National Security Complex (Y-12)"
  LAB = /\b((?:[A-Z][A-Za-z0-9]*(?:-[A-Za-z0-9]+)*\s)+National (?:Laboratory|Security Complex))\s\(([A-Z0-9-]+)\)/
  # A sentence naming labs must be about isotopes being produced or processed there.
  PRODUCTION = /\b(?:production of isotopes|processing isotopes|isotope produc)/i
  # "The DOE IRP's University Isotope Network (UIN) comprises six schools: the University of …"
  NETWORK = /University Isotope Network.*?\bcomprises\s+\w+\s+schools:\s+(.+)\.\z/
  NETWORK_NOTE = "The page names it in DOE's University Isotope Network, which DOE partners with to develop " \
    "isotope production; it doesn't say the school produces isotopes itself. Approve only if that's enough."

  # The page has neither sentence to extract from.
  class LayoutChanged < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(_run)
    page = Source.find_or_create_by!(url: PAGE_URL) do |source|
      source.source_kind = source_kind
      source.title = "DOE Isotope Program: production sites"
    end
    # A page someone cited by hand (a plain web_page source) becomes this plug-in's, so it's extracted.
    page.update!(source_kind:) if page.source_kind == "web_page"
    stats = { "page" => DataQuality::Snapshot.take(page, fetcher: @fetcher).to_s }
    return stats.merge("stopped" => "page blocked") if stats["page"] == "blocked"
    return stats unless page.crawl_ok? && page.content_text.present?

    labs, schools = sites(page.content_text)
    if labs.empty? || schools.empty?
      page.update!(crawl_status: "needs_human", status_reason: LAYOUT_CHANGED)
      return stats.merge("labs" => labs.size, "schools" => schools.size)
    end
    stats.merge("labs" => labs.size, "schools" => schools.size)
  end

  def extract(source, _run)
    labs, schools = sites(source.content_text)
    raise LayoutChanged, "#{LAYOUT_CHANGED} (#{source.url})" if labs.empty? || schools.empty?

    labs.flat_map { |lab| candidates(lab, type: (lab.name.include?("National Laboratory") ? "national_lab" : nil)) } +
      schools.flat_map { |school| candidates(school, type: (school.name.include?("University") ? "university" : nil)) }
  end

  # The sentences the names come from: the page around them carries menus
  # and a date-free footer, but only these hold facts.
  def rows_sha256(source)
    text = sentences(source.content_text).join("\n")
    Digest::SHA256.hexdigest(text) if text.present?
  end

  # A school's isotopes claim rests on network membership alone.
  def hold_for_review(candidate)
    return unless candidate.kind == "organization_role" && candidate.payload["role"] == "isotopes"

    NETWORK_NOTE if candidate.quote.to_s.match?(NETWORK)
  end

  def source_facts(source)
    return unless source.url == PAGE_URL

    "This is the US Department of Energy Isotope Program's (DOE IRP) page of its isotope production sites. " \
      "A national laboratory it names in a sentence about producing or processing isotopes is a DOE isotope " \
      "production site. A name containing \"National Laboratory\" is a national laboratory, and one containing " \
      "\"University\" is a university."
  end

  Site = Data.define(:name, :abbreviation, :quote)

  private
    # [labs, schools], each a Site with the sentence that names it, first
    # mention only, in the page's order.
    def sites(html)
      all = sentences(html)
      labs = all.select { |sentence| sentence.match?(PRODUCTION) }.flat_map do |sentence|
        sentence.scan(LAB).map { |name, abbreviation| Site.new(name: name.strip, abbreviation:, quote: sentence) }
      end
      schools = all.filter_map { |sentence| [ sentence, sentence[NETWORK, 1] ] if sentence.match?(NETWORK) }.flat_map do |sentence, list|
        list.split(/,\s*(?:and\s+)?|\s+and\s+/).map { |name| name.strip.delete_prefix("the ") }.compact_blank
          .map { |name| Site.new(name:, abbreviation: nil, quote: sentence) }
      end
      [ labs.uniq(&:name), schools.uniq(&:name) ]
    end

    # The page's paragraphs as sentences, pieces joined by spaces as the
    # shared quote check reads a page. "U.S." doesn't end a sentence.
    def sentences(html)
      @sentences ||= {}
      @sentences[html.hash] ||= Nokogiri::HTML(html.to_s).css("main p, article p").flat_map do |paragraph|
        paragraph.xpath(".//text()").map(&:text).join(" ").squish.split(/(?<!\bU\.S)(?<=\.)\s+(?=[A-Z])/)
      end
    end

    def candidates(site, type:)
      organization = { "name" => site.name }
      company = { kind: "organization", quote: site.quote,
        payload: organization.merge({ "aliases" => ([ site.abbreviation ] if site.abbreviation && site.abbreviation != site.name) }.compact) }
      isotopes = { kind: "organization_role", quote: site.quote, payload: { "organization" => organization, "role" => "isotopes" } }
      kind = { kind: "organization_role", quote: site.quote, payload: { "organization" => organization, "role" => type } } if type
      [ company, isotopes, kind ].compact
    end
end
