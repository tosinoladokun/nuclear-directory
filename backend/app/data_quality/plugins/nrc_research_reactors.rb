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
  NO_FACTS = "The reactor's page has no title, Docket Number or Reactor Type; the page layout may have changed"
  UNLISTED = "NRC's research and test reactor table no longer links this reactor"
  LISTED_AGAIN = "NRC's research and test reactor table links this reactor again"
  FIELDS = [ "Licensee", "Location", "Docket Number", "Reactor Type" ].freeze
  STATE_CODES = LinkCard::US_STATES.invert.merge(LinkCard::US_STATES.keys.to_h { |code| [ code, code ] }).freeze

  Row = Data.define(:listed_name, :location, :path)
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
      result, page = read(row)
      stats["reactor_pages"][result] += 1
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
  # Pages never read before, at most 15 reactor pages a night (about 40 claims), so Data Quality reads
  # each night's batch claim by claim (#541); pages read before are never held back.
  def new_sources_per_run = 15

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
      rows = table.css("tr").reject { |tr| tr.css("td").empty? } # header rows are th only
      read = rows.filter_map do |tr|
        cells = tr.css("td")
        link = cells[1]&.at_css("a[href]")
        next unless cells.size >= 3 && link && link["href"].start_with?("/facilities-safety/facility-finder/nonpower/")

        Row.new(listed_name: link.text.squish, location: cells[2].text.squish, path: link["href"])
      end
      # A row without its page link makes the whole read unusable: a partial
      # list would look like reactors leaving it.
      read.size == rows.size ? read : []
    end

    def read(row)
      source = Source.find_or_create_by!(url: "#{NRC}#{row.path}") do |new_source|
        new_source.source_kind = source_kind
        new_source.title = "NRC research reactor: #{row.listed_name}"
      end
      # A page someone cited by hand becomes this plug-in's; its stored copy is
      # the whole page, so it's fetched afresh and converted.
      take_over(source)
      return [ "another_kind", nil ] unless source.source_kind == source_kind

      [ DataQuality::Snapshot.take(source, fetcher: @fetcher) { |html| stored_line(html, row) }.to_s, source.reload ]
    rescue Unreadable
      source.update!(crawl_status: "needs_human", status_reason: NO_FACTS)
      hold_open(source, NO_FACTS)
      [ "needs_human", source ]
    end

    # The page's own facts; never the page's people. NRC titles a reactor's
    # page with its licensee ("Texas A&M University") and names no reactor,
    # so the reactor is named from the licensee and its reactor type ("Texas
    # A&M University TRIGA reactor"), which tells a licensee's two apart.
    def stored_line(html, _row)
      doc = Nokogiri::HTML(html.to_s)
      licensee = doc.at_css("main h1, h1")&.text.to_s.squish
      facts = { "Licensee" => licensee.presence, "Location" => value_after(doc, "Location"),
        "Docket Number" => value_after(doc, "Docket Number"), "Reactor Type" => value_after(doc, "Reactor Type") }.compact
      raise Unreadable if licensee.empty? || facts["Docket Number"].blank? || facts["Reactor Type"].blank?

      Reactor.new(name: "#{licensee} #{facts['Reactor Type']} reactor", facts:).line
    end

    def value_after(doc, label)
      strong = doc.css("strong").find { |node| node.text.gsub(/[[:space:]]+/, " ").strip.delete_suffix(":").strip == label } or return
      # A table row: the label's cell, then the value's.
      if (cell = strong.ancestors("td").first) && cell.text.squish.delete_suffix(":").strip == label
        return cell.next_element&.text.to_s.gsub(/[[:space:]]+/, " ").strip.presence
      end

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
