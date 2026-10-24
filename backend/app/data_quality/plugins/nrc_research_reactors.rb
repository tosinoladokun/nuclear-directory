# NRC's licensed research and test reactors (#387), for Government and
# research: the table "Locations of Research and Test Reactors" on NRC's
# non-power reactor page, and each reactor's own page.
#
# Crawl fetches the locations page (an index, never extracted), then each
# reactor page its table links, at most once a day through the shared
# Fetcher. It stores one line per reactor from the page alone: its name and
# its Licensee, Location, Docket Number and Reactor Type. Never the page's
# contacts. A reactor the table stops linking has its waiting claims sent
# to review (and its published facts flagged), until it's linked again. A block stops the
# crawl (a same-day rerun too); a page without a name, licensee or docket
# goes to a person. The medical
# isotope and advanced reactor tables aren't read (applications and
# construction, not licensed reactors).
#
# Extract proposes the reactor (research_reactor, docket, city, state) and
# its licensee, and university or national_lab only where the licensee's own
# name says so. No operates link and no power level: the page doesn't state
# that the reactor runs, and where thermal power goes is undecided (#387).
class DataQuality::Plugins::NrcResearchReactors < DataQuality::Plugin
  include DataQuality::UnlistedPages

  NRC = "https://www.nrc.gov".freeze
  LIST_URL = "https://www.nrc.gov/facilities-safety/facility-finder/nonpower".freeze
  INDEX_SOURCE_KIND = "nrc_research_reactors_index"
  TABLE_SUMMARY = "Locations of Research and Test Reactors"
  NO_TABLE = "Couldn't find the table of research and test reactors; the page layout may have changed"
  NO_FACTS = "The reactor's page has no name, Licensee or Docket Number; the page layout may have changed"
  UNLISTED = "NRC's research and test reactor table no longer links this reactor"
  LISTED_AGAIN = "NRC's research and test reactor table links this reactor again"
  FIELDS = [ "Licensee", "Location", "Docket Number", "Reactor Type" ].freeze
  STATE_CODES = LinkCard::US_STATES.invert.merge(LinkCard::US_STATES.keys.to_h { |code| [ code, code ] }).freeze

  Row = Data.define(:licensee, :location, :path)
  Reactor = Data.define(:name, :facts) do
    def line = [ name, *FIELDS.filter_map { |label| "#{label}: #{facts[label]}" if facts[label] } ].join(" | ")
    def city = facts["Location"].to_s[/\A([^,]+),/, 1]&.strip
    def state = STATE_CODES[facts["Location"].to_s[/,\s*([A-Za-z ]+)\z/, 1].to_s.strip]

    # Only what the licensee's own name says.
    def kind_role
      licensee = facts["Licensee"].to_s
      if licensee.match?(/National Laborator(?:y|ies)/i) then "national_lab"
      elsif licensee.match?(/\b(?:University|College|Institute of Technology|Polytechnic Institute)\b/i) then "university"
      end
    end
  end

  # A reactor page with nothing to store.
  class Unreadable < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(run)
    list = Source.find_or_create_by!(url: LIST_URL) do |row|
      row.source_kind = INDEX_SOURCE_KIND
      row.title = "NRC: locations of non-power reactors"
    end
    stats = { "list" => DataQuality::Snapshot.take(list, fetcher: @fetcher).to_s }
    return stats.merge("stopped" => "list page blocked") if stats["list"] == "blocked"
    return stats unless list.crawl_ok? && list.content_text.present?

    rows = rows(list.content_text)
    if rows.empty?
      list.update!(crawl_status: "needs_human", status_reason: NO_TABLE)
      return stats.merge("reactors" => 0)
    end
    stats.merge!("reactors" => rows.size, "reactor_pages" => Hash.new(0))
    withdrawn = withdraw_unlisted(rows.map { |row| "#{NRC}#{row.path}" }, run, UNLISTED)
    stats["withdrawn"] = withdrawn if withdrawn.positive?
    rows.each do |row|
      result = read(row)
      stats["reactor_pages"][result] += 1
      page = Source.find_by(url: "#{NRC}#{row.path}")
      # A block recorded earlier today stops a same-day rerun too, before any later page.
      return stats.merge("stopped" => "reactor page blocked") if result == "blocked" || (page && still_blocked?(page))

      restored = page ? restore_listed(page, LISTED_AGAIN) : 0
      stats["restored"] = stats.fetch("restored", 0) + restored if restored.positive?
    end
    stats
  end

  def extract(source, _run)
    reactor = parse(source.content_text) or return []

    site = { "name" => reactor.name, "facility_type" => "research_reactor", "nrc_docket" => reactor.facts["Docket Number"],
      "country_code" => "US", "city" => reactor.city, "state" => reactor.state }.compact
    licensee = { "name" => reactor.facts["Licensee"] }
    claims = [ { kind: "facility", quote: reactor.line, payload: site }, { kind: "organization", quote: reactor.line, payload: licensee } ]
    claims << { kind: "organization_role", quote: reactor.line, payload: { "organization" => licensee, "role" => reactor.kind_role } } if reactor.kind_role
    claims
  end

  # One reactor per page: anything it stops stating goes to a person.
  def max_dropped_share(_source) = 1.0

  def quote_in_source?(source, quote) = source.content_text.to_s == quote.to_s

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is the U.S. Nuclear Regulatory Commission's record of one licensed research or test reactor in the United " \
      "States (country code US): its name, the organization holding its NRC license (Licensee), its location, NRC " \
      "docket and reactor type."
  end

  private
    def rows(html)
      table = Nokogiri::HTML(html.to_s).at_css(%(table[summary="#{TABLE_SUMMARY}"])) or return []
      table.css("tr").filter_map do |tr|
        cells = tr.css("td")
        link = cells[1]&.at_css("a[href]")
        next unless cells.size >= 3 && link && link["href"].start_with?("/facilities-safety/facility-finder/nonpower/")

        Row.new(licensee: link.text.squish, location: cells[2].text.squish, path: link["href"])
      end
    end

    def read(row)
      source = Source.find_or_create_by!(url: "#{NRC}#{row.path}") do |new_source|
        new_source.source_kind = source_kind
        new_source.title = "NRC: #{row.licensee} research reactor"
      end
      # A page someone cited by hand becomes this plug-in's; its stored copy is
      # the whole page, so it's fetched afresh and converted.
      if source.source_kind == "web_page"
        source.update!(source_kind:, fetched_at: nil, etag: nil, last_modified: nil, content_text: nil, content_sha256: nil, extracted_sha256: nil)
      end
      return "another_kind" unless source.source_kind == source_kind

      DataQuality::Snapshot.take(source, fetcher: @fetcher) { |html| stored_line(html, row) }.to_s
    rescue Unreadable
      source.update!(crawl_status: "needs_human", status_reason: NO_FACTS)
      "needs_human"
    end

    # The page's own name and labelled facts; never the page's people. The
    # table's Name column names the reactor, not always its licensee.
    def stored_line(html, _row)
      doc = Nokogiri::HTML(html.to_s)
      name = doc.at_css("main h1, h1")&.text.to_s.squish
      facts = FIELDS.to_h { |label| [ label, value_after(doc, label) ] }.compact
      raise Unreadable if name.empty? || facts["Licensee"].blank? || facts["Docket Number"].blank?

      Reactor.new(name:, facts:).line
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
      return if name.blank? || facts["Docket Number"].blank? || facts["Licensee"].blank? || (facts.keys - FIELDS).any?

      Reactor.new(name:, facts:)
    end
end
