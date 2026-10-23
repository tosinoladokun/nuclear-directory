# DOE program pages (#124): the companies DOE itself names on its
# programs' pages, with what DOE says it did for them. First, the HALEU
# Availability Program's three pages that list companies: enrichment
# services, deconversion services and HALEU allocations.
#
# Crawl fetches each page in PAGES once a day through the shared Fetcher; a
# block is recorded and that page is skipped, never worked around. A page
# where a list it expects can't be found is marked needs_human.
#
# Extract reads only the lists PAGES names: each list follows a sentence or
# heading the page itself writes (LIST.after), and each item names one
# company (two joined by "/" are two). Each gives the company and DOE's link
# to it (funds for a contract, supplies for a HALEU allocation), described
# in the page's own terms and quoting the item. No roles: being selected to
# bid doesn't say what a company does yet. No model is asked. Match, verify
# and a person's approval are shared.
#
# ARDP's page names no companies (its infographic is an image), INL's GAIN
# pages answer our bot with 403, and the fusion milestone program's page
# moved; those come later from their own lists.
class DataQuality::Plugins::DoePrograms < DataQuality::Plugin
  DOE = "U.S. Department of Energy"
  LAYOUT_CHANGED = "Couldn't find a list of companies this page used to have; the page layout may have changed"

  List = Data.define(:after, :relationship_type, :description)
  PAGES = {
    "https://www.energy.gov/ne/haleu-enrichment-services" => {
      title: "DOE: HALEU enrichment services",
      lists: [
        List.new(after: /DOE selected four companies and allocated \$2 million to each vendor/, relationship_type: "funds",
          description: "HALEU enrichment services contract: selected in 2024 to bid on task orders"),
        List.new(after: /DOE finalized task orders with the following companies/, relationship_type: "funds",
          description: "HALEU enrichment services task order, finalized January 5, 2026")
      ]
    },
    "https://www.energy.gov/ne/haleu-deconversion-services" => {
      title: "DOE: HALEU deconversion services",
      lists: [
        List.new(after: /\ASelected companies include:/, relationship_type: "funds",
          description: "HALEU deconversion services contract, to bid on deconversion work")
      ]
    },
    "https://www.energy.gov/ne/us-department-energy-haleu-allocation-process" => {
      title: "DOE: HALEU allocation process",
      lists: [
        List.new(after: /\ARound 1 Conditional Selections/, relationship_type: "supplies", description: "Conditional HALEU allocation, round 1 (April 9, 2025)"),
        List.new(after: /\ARound 2 Conditional Selections/, relationship_type: "supplies", description: "Conditional HALEU allocation, round 2 (August 26, 2025)"),
        List.new(after: /\ARound 3 Conditional Selections/, relationship_type: "supplies", description: "Conditional HALEU allocation, round 3 (July 23, 2026)")
      ]
    }
  }.freeze

  # A page missing a list it should have.
  class LayoutChanged < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new, pages: PAGES)
    @fetcher = fetcher
    @pages = pages
  end

  def crawl(_run)
    @pages.each_with_object({}) do |(url, page), stats|
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = page[:title]
      end
      source.update!(source_kind:) if source.source_kind == "web_page"
      stats[page[:title]] = DataQuality::Snapshot.take(source, fetcher: @fetcher).to_s
      next unless source.crawl_ok? && source.content_text.present?

      items = items(source)
      if items.nil?
        source.update!(crawl_status: "needs_human", status_reason: LAYOUT_CHANGED)
        stats[page[:title]] = "layout_changed"
      else
        stats["companies"] = stats.fetch("companies", 0) + items.size
      end
    end
  end

  def extract(source, _run)
    items = items(source) or raise LayoutChanged, "#{LAYOUT_CHANGED} (#{source.url})"

    items.flat_map do |quote, name, list|
      [
        { kind: "organization", quote:, payload: { "name" => name } },
        { kind: "relationship", quote:, payload: { "from_organization" => { "name" => DOE }, "to_organization" => { "name" => name },
          "relationship_type" => list.relationship_type, "description" => list.description } }
      ]
    end
  end

  # A few lists per page: a company leaving one is a real change for a person to see.
  def max_dropped_share(_source) = 1.0

  # Only the lists extract reads, so the page's news panel changing isn't a change.
  def rows_sha256(source)
    items = items(source) or return
    Digest::SHA256.hexdigest(items.map { |quote, _, list| [ list.description, quote ].join("\t") }.join("\n"))
  end

  def quote_in_source?(source, quote) = Array(items(source)).any? { |each, _, _| each == quote.to_s.squish }

  # The item with the sentence or heading its list follows.
  def verification_context(source, quote)
    blocks = blocks(source)
    Array(items(source)).filter_map do |each, _, list|
      next unless each == quote.to_s.squish

      [ blocks.find { |block| block.match?(list.after) }, each ].compact.join("\n")
    end.uniq.join("\n\n").presence
  end

  def source_facts(source)
    page = @pages[source.url] or return
    "This is the U.S. Department of Energy's own page, \"#{page[:title].delete_prefix('DOE: ')}\". Each list item is a " \
      "company DOE names under the sentence or heading before the list, which says what DOE did with it."
  end

  private
    # [[quote, company name, List]] for the page's lists, or nil when one is missing.
    def items(source)
      page = @pages[source.url] or return []
      lists = lists(source)
      page[:lists].each_with_object([]) do |list, found|
        ul = lists.find { |heading, _| heading.match?(list.after) }&.last or return nil

        ul.css("li").each do |li|
          quote = li.text.gsub(/[[:space:]]+/, " ").strip
          next if quote.empty?

          names(quote).each { |name| found << [ quote, name, list ] }
        end
      end
    end

    # "American Centrifuge Operating ($900 million)" => American Centrifuge
    # Operating; "Abilene Christian University/Natura Resources LLC" => both.
    def names(quote) = quote.sub(/\s*\([^)]*\)\s*\z/, "").split("/").map(&:strip).reject(&:empty?)

    # [[text before it, ul]]: each list with the paragraph, or accordion
    # heading, that comes right before it on the page.
    def lists(source)
      doc(source).css("ul").filter_map do |ul|
        next if ul.ancestors("nav, header, footer").any?

        before = ul.xpath("preceding-sibling::*[1]").first&.text
        before = ul.ancestors("[id^='energy-accordion']").first&.xpath("preceding-sibling::*[1]")&.text if before.blank?
        [ before.to_s.gsub(/[[:space:]]+/, " ").strip, ul ] if before.present?
      end
    end

    def blocks(source) = lists(source).map(&:first)

    def doc(source)
      @docs ||= {}
      @docs[source.content_sha256 || source.content_text.hash] ||= Nokogiri::HTML(source.content_text.to_s).then { |html| html.at_css("main") || html }
    end
end
