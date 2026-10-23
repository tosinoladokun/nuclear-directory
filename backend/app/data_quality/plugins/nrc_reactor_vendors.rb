# Which company supplied each operating power reactor (#388): the
# "Reactor Vendor/Type" line on each unit's NRC page, for the plant
# profile's reactor developer (a vendor_for link).
#
# Crawl reads the unit pages the NRC reactor list links to (its stored
# copy, from nrc_reactor_list, which runs first), each at most once a day
# through the shared Fetcher, and stores only the unit's name, docket and
# vendor line, never the page's contacts. A block stops the crawl; a page
# without a vendor line goes to a person.
#
# Extract names the vendor only as the page writes it, from a known
# vendor's name at the start of the line (VENDORS); a line naming no known
# vendor proposes nothing. Never inferred from the reactor type. Historical
# vendors keep their name (Combustion Engineering): whether that's an alias
# or a former company is a person's call. No model is asked.
class DataQuality::Plugins::NrcReactorVendors < DataQuality::Plugin
  NRC = "https://www.nrc.gov".freeze
  UNIT_PATH = "/facilities-safety/facility-finder/reactors/".freeze
  LABEL = "Reactor Vendor/Type"
  NO_VENDOR_LINE = "The unit's page has no Reactor Vendor/Type line; the page layout may have changed"
  # The line's start => the company, as NRC names it.
  VENDORS = {
    /\AWestinghouse\b/i => "Westinghouse",
    /\AGeneral Electric\b|\AGE\b/i => "General Electric",
    /\ACombustion[- ]Engineering\b/i => "Combustion Engineering",
    /\ABabcock (?:&|and) Wilcox\b/i => "Babcock & Wilcox"
  }.freeze

  Unit = Data.define(:name, :docket, :vendor_line) do
    def line = "#{name} | Docket Number: #{docket} | #{LABEL}: #{vendor_line}"
    def vendor = VENDORS.find { |pattern, _| vendor_line.match?(pattern) }&.last
  end

  # A unit page with no vendor line to store.
  class Unreadable < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(_run)
    list = Source.find_by(url: DataQuality::Plugins::NrcReactorList::LIST_URL)
    return { "units" => "no reactor list yet" } unless list&.content_text.present?

    all = DataQuality::Plugins::NrcReactorList::Page.units(list.content_text)
    # Units NRC lists under its operating-reactor pages; a new plant's
    # licensing page (Vogtle 3 and 4) is another layout, left out.
    units = all.select { |unit| unit.nrc_path.to_s.start_with?(UNIT_PATH) }
    stats = { "units" => units.size, "unit_pages" => Hash.new(0) }
    stats["other_pages"] = all.size - units.size if all.size > units.size
    units.each do |unit|
      result = read(unit)
      stats["unit_pages"][result] += 1
      return stats.merge("stopped" => "unit page blocked") if result == "blocked"
    end
    stats
  end

  def extract(source, _run)
    unit = unit_from(source.content_text) or return []
    vendor = unit.vendor or return []

    [
      { kind: "organization", quote: unit.line, payload: { "name" => vendor } },
      { kind: "facility_relationship", quote: unit.line, payload: { "organization" => { "name" => vendor },
        "facility" => { "name" => unit.name, "nrc_docket" => unit.docket }, "relationship_type" => "vendor_for" } }
    ]
  end

  # One unit per page: a vendor line gone is a real change for a person to see.
  def max_dropped_share(_source) = 1.0

  def quote_in_source?(source, quote) = source.content_text.to_s == quote.to_s

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is the U.S. Nuclear Regulatory Commission's page for one operating power reactor unit: its name, NRC " \
      "docket, and the \"Reactor Vendor/Type\" line, which names the company that supplied the reactor and its model."
  end

  private
    def read(unit)
      source = Source.find_or_create_by!(url: "#{NRC}#{unit.nrc_path}") do |row|
        row.source_kind = source_kind
        row.title = "NRC: #{unit.name}"
      end
      source.update!(source_kind:) if source.source_kind == "web_page"
      return "another_kind" unless source.source_kind == source_kind

      DataQuality::Snapshot.take(source, fetcher: @fetcher) { |html| stored_line(html, unit) }.to_s
    rescue Unreadable
      source.update!(crawl_status: "needs_human", status_reason: NO_VENDOR_LINE)
      "needs_human"
    end

    # Only the unit's name, docket and vendor line: never the page's people.
    def stored_line(html, unit)
      doc = Nokogiri::HTML(html.to_s)
      label = doc.css("strong").find { |strong| strong.text.squish.delete_suffix(":") == LABEL } or raise Unreadable
      value = []
      node = label.next_sibling
      while node && node.name != "br" && node.name != "strong"
        value << node.text
        node = node.next_sibling
      end
      vendor_line = value.join.gsub(/[[:space:]]+/, " ").strip
      raise Unreadable if vendor_line.empty?

      # The page's own name for the unit ("Arkansas Nuclear One, Unit 1"); the docket is the list's.
      name = doc.at_css("main h1, h1")&.text.to_s.squish.presence || unit.name
      Unit.new(name:, docket: unit.nrc_docket, vendor_line:).line
    end

    def unit_from(text)
      name, docket, vendor = text.to_s.split(" | ", 3)
      return unless docket&.start_with?("Docket Number: ") && vendor&.start_with?("#{LABEL}: ")

      Unit.new(name:, docket: docket.delete_prefix("Docket Number: "), vendor_line: vendor.delete_prefix("#{LABEL}: "))
    end
end
