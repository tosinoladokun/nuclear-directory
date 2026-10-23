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
          description: "HALEU enrichment services task order, finalized %<date>s")
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
        List.new(after: /\ARound 1 Conditional Selections/, relationship_type: "supplies", description: "Conditional HALEU allocation, round 1 (%<date>s)"),
        List.new(after: /\ARound 2 Conditional Selections/, relationship_type: "supplies", description: "Conditional HALEU allocation, round 2 (%<date>s)"),
        List.new(after: /\ARound 3 Conditional Selections/, relationship_type: "supplies", description: "Conditional HALEU allocation, round 3 (%<date>s)")
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

    companies = items.map { |item| { kind: "organization", quote: item.quote, payload: { "name" => item.name } } }
    # One link per company and kind of link on a page, however many of its
    # lists name it: a second claim would replace the first one's description.
    links = items.group_by { |item| [ key(item.name), item.list.relationship_type ] }.map do |_, group|
      { kind: "relationship", quote: group.first.quote, payload: { "from_organization" => { "name" => DOE },
        "to_organization" => { "name" => group.first.name }, "relationship_type" => group.first.list.relationship_type,
        "description" => group.map(&:description).uniq.join("; ") } }
    end
    companies + links
  end

  # A few lists per page: a company leaving one is a real change for a person to see.
  def max_dropped_share(_source) = 1.0

  # The lists extract reads, with the sentence or heading each follows, so
  # the page's news panel changing isn't a change and a heading's changing is.
  def rows_sha256(source)
    items = items(source) or return
    Digest::SHA256.hexdigest(items.map { |item| [ item.context, item.quote ].join("\t") }.join("\n"))
  end

  def quote_in_source?(source, quote) = Array(items(source)).any? { |item| item.quote == quote.to_s.squish }

  # The item with what the page says before its list, for every list that
  # names the same company: what the claim's description sums up.
  def verification_context(source, quote)
    items = Array(items(source))
    named = items.select { |item| item.quote == quote.to_s.squish }.map { |item| key(item.name) }
    items.select { |item| named.include?(key(item.name)) }.map { |item| [ item.context, item.quote ].join("\n") }.uniq.join("\n\n").presence
  end

  def source_facts(source)
    page = @pages[source.url] or return
    "This is the U.S. Department of Energy's own page, \"#{page[:title].delete_prefix('DOE: ')}\". Each list item is a " \
      "company DOE names under the sentence or heading before the list, which says what DOE did with it."
  end

  private
    Item = Data.define(:quote, :name, :list, :context, :description)

    # The page's lists' items, or nil when a list is missing, names no one,
    # or its heading no longer gives the date its description needs.
    def items(source)
      page = @pages[source.url] or return []
      lists = lists(source)
      page[:lists].each_with_object([]) do |list, found|
        context, ul = lists.find { |heading, _, _| heading.match?(list.after) }&.then { |heading, before, each| [ [ before, heading ].compact.join("\n"), each ] }
        return nil unless ul

        description = describe(list, context) or return nil
        entries = ul.css("li").map { |li| li.text.gsub(/[[:space:]]+/, " ").strip }.reject(&:empty?)
        return nil if entries.empty?

        entries.each { |quote| names(quote).each { |name| found << Item.new(quote:, name:, list:, context:, description:) } }
      end
    end

    DATE = /\b((?:January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}, \d{4})\b/

    def describe(list, context)
      return list.description unless list.description.include?("%<date>s")

      date = context[DATE, 1] or return
      format(list.description, date:)
    end

    # "American Centrifuge Operating ($900 million)" => American Centrifuge
    # Operating; "Abilene Christian University/Natura Resources LLC" => both.
    def names(quote) = quote.sub(/\s*\([^)]*\)\s*\z/, "").split("/").map(&:strip).reject(&:empty?)

    # A name without its legal words, to see two spellings are one company
    # on a page ("General Matter Inc." and "General Matter").
    def key(name) = name.downcase.sub(/,?\s+(?:inc|llc|l\.l\.c|corp|corporation|company|co|ltd)\.?\z/, "").squish

    # [[the paragraph or accordion heading right before it, the paragraph
    # before that (what it says DOE did), ul]] for each list on the page.
    def lists(source)
      doc(source).css("ul").filter_map do |ul|
        next if ul.ancestors("nav, header, footer").any?

        anchor = ul.xpath("preceding-sibling::*[1]").first&.text.present? ? ul : ul.ancestors("[id^='energy-accordion']").first
        heading = anchor&.xpath("preceding-sibling::*[1]")&.first
        next if heading.nil? || heading.text.blank?

        before = heading.xpath("preceding-sibling::*[1]").first&.text
        [ text(heading.text), (text(before) if before.present?), ul ]
      end
    end

    def text(value) = value.to_s.gsub(/[[:space:]]+/, " ").strip

    def doc(source)
      @docs ||= {}
      @docs[source.content_sha256 || source.content_text.hash] ||= Nokogiri::HTML(source.content_text.to_s).then { |html| html.at_css("main") || html }
    end
end
