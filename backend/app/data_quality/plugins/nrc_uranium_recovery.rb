# NRC's uranium recovery facilities (#275), for Fuel and materials (tag:
# uranium): the sites the NRC itself licenses, from its "Locations of
# Uranium Recovery Facilities" page.
#
# Crawl fetches that page once a day through the shared Fetcher; a block is
# recorded and stops the crawl, and a page without the NRC-licensed table
# is marked needs_human.
#
# Extract reads only the table of NRC-licensed facilities (Site Name |
# Licensee | Location | Type of Facility). Each row gives the site (in situ
# recovery as uranium_mine, a conventional mill as mill; city and state
# from Location) and its licensee, quoting the row. No link or role: a
# licensee row doesn't say the company runs the site (two of the three are
# unbuilt, one stopped) or what it does, so those wait for a source that
# says so (Data Quality, 22 Oct). A row whose type or state can't be read
# is held for a person at verify. No model is asked. The page's second table,
# of sites Agreement States license, isn't read: NRC says it was last
# updated in 2018 and makes no claim about it (those sites are #384, from
# each state's own list). Match, verify and approval are shared.
class DataQuality::Plugins::NrcUraniumRecovery < DataQuality::Plugin
  PAGE_URL = "https://www.nrc.gov/facilities-safety/facility-finder/materials/uranium"
  TABLE_SUMMARY = "NRC-Licensed Uranium Recovery Facilities"
  TABLE_MISSING = "Couldn't find the table of NRC-licensed uranium recovery facilities; the page layout may have changed"
  ROW_UNREADABLE = "A row of the NRC-licensed table has no site name, licensee, location or type"
  FACILITY_TYPES = { /\AIn Situ Recovery\b/ => "uranium_mine", /\AConventional Uranium Mill\b/ => "mill" }.freeze
  # "Chadron, Nebraska" => "NE": the app's one list of state names.
  STATE_CODES = LinkCard::US_STATES.invert.freeze

  Row = Data.define(:site, :licensee, :location, :type, :line) do
    def city = location[/\A([^,]+),\s*[A-Za-z ]+\z/, 1]&.then { |place| place unless place.match?(/\bCount(?:y|ies)\b/) }
    def state = STATE_CODES[location[/,\s*([A-Za-z ]+)\z/, 1].to_s.strip]
    def facility_type = FACILITY_TYPES.find { |pattern, _| type.match?(pattern) }&.last
  end

  # The stored page has no NRC-licensed table to extract from.
  class TableMissing < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(_run)
    page = Source.find_or_create_by!(url: PAGE_URL) do |source|
      source.source_kind = source_kind
      source.title = "NRC: locations of uranium recovery facilities"
    end
    # A page someone cited by hand (a plain web_page source) becomes this plug-in's, so it's extracted.
    page.update!(source_kind:) if page.source_kind == "web_page"
    stats = { "page" => DataQuality::Snapshot.take(page, fetcher: @fetcher).to_s }
    return stats.merge("stopped" => "page blocked") if stats["page"] == "blocked"
    return stats unless page.crawl_ok? && page.content_text.present?

    rows, unreadable = rows(page.content_text)
    if rows.empty? || unreadable.positive?
      page.update!(crawl_status: "needs_human", status_reason: unreadable.positive? ? ROW_UNREADABLE : TABLE_MISSING)
      return stats.merge("sites" => rows.size, "unreadable_rows" => unreadable).reject { |key, count| key == "unreadable_rows" && count.zero? }
    end
    stats.merge("sites" => rows.size)
  end

  def extract(source, _run)
    rows, unreadable = rows(source.content_text)
    raise TableMissing, "#{TABLE_MISSING} (#{source.url})" if rows.empty?
    # A partial read would look like sites leaving the table: nothing is written.
    raise TableMissing, "#{ROW_UNREADABLE} (#{source.url})" if unreadable.positive?

    rows.flat_map { |row| candidates(row) }
  end

  # A table of a few rows: one site gone is a third of its facts, and is a
  # real change, never a broken page (a read that finds no rows raises
  # before anything is written). Any fact it stops stating goes to a
  # person; nothing is unpublished.
  def max_dropped_share(_source) = 1.0

  # The NRC-licensed table's rows only: the page around them changes on its own.
  def rows_sha256(source)
    lines = lines(source.content_text)
    Digest::SHA256.hexdigest(lines.join("\n")) if lines.size > 1
  end

  # Quotes are whole rows of the table, as lines renders them.
  def quote_in_source?(source, quote) = lines(source.content_text).include?(quote)

  def verification_context(source, quote) = [ lines(source.content_text).first, quote ].compact.join("\n")

  # A site whose type or state the row gave in words this plug-in can't
  # read: matched first, so its links resolve, then held for a person.
  def hold_for_review(candidate)
    return unless candidate.kind == "facility"

    unread = [ ("type of facility" unless candidate.payload["facility_type"]), ("state" unless candidate.payload["state"]) ].compact
    "Couldn't read the row's #{unread.join(' and ')}; check the site's values against the quote" if unread.any?
  end

  def source_facts(source)
    return unless source.url == PAGE_URL

    "This is the NRC's table of NRC-licensed uranium recovery facilities in the United States: each row is a " \
      "uranium recovery site (country code US), the company that holds its NRC license (the Licensee), its " \
      "location and its type of facility as the NRC names it (In Situ Recovery or Conventional Uranium Mill)."
  end

  private
    # [rows, how many data rows couldn't be read]. A row missing any of its
    # four values makes the whole read unusable (the caller stops).
    def rows(html)
      table = table_in(html) or return [ [], 0 ]
      data = table.css("tr").reject { |row| row.css("td").empty? }
      read = data.filter_map do |row|
        cells = row.css("td").map { |cell| cell.text.squish }
        next if cells.size < 4 || cells.first(4).any?(&:blank?)

        Row.new(site: cells[0], licensee: cells[1], location: cells[2], type: cells[3], line: line(row))
      end
      [ read, data.size - read.size ]
    end

    def lines(html)
      @lines ||= {}
      @lines[html.hash] ||= table_in(html)&.css("tr")&.map { |row| line(row) } || []
    end

    def line(row) = row.css("th, td").map { |cell| cell.text.squish }.join(" | ")

    def table_in(html)
      doc = Nokogiri::HTML(html.to_s)
      doc.at_css(%(table[summary="#{TABLE_SUMMARY}"])) ||
        doc.css("table").find { |table| table.css("th").map { |th| th.text.squish }.first(2) == [ "Site Name", "Licensee" ] }
    end

    def candidates(row)
      site = { "name" => row.site, "facility_type" => row.facility_type, "country_code" => "US", "city" => row.city,
        "state" => row.state }.compact
      [
        { kind: "facility", quote: row.line, payload: site },
        { kind: "organization", quote: row.line, payload: { "name" => row.licensee } }
      ]
    end
end
