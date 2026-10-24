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

  SUPERSEDED = "Superseded: DOE's program pages changed, so the link is read again"
  REPLACEMENT = "It replaces a claim from an earlier read of DOE's pages: check it as a first read"

  # A link claim that replaces a superseded one waits for a person, as its
  # first read did, so no recommendation can take it in bulk.
  def hold_for_review(candidate)
    return unless candidate.kind == "relationship"

    # By the same name key as extraction ("General Matter Inc." is "General Matter").
    name = key(candidate.payload.dig("to_organization", "name").to_s)
    superseded = Candidate.where(source_id: Source.where(source_kind:).select(:id), kind: "relationship", status: "rejected", notes: SUPERSEDED)
      .pluck(Arel.sql("candidates.payload->'to_organization'->>'name'"))
    REPLACEMENT if superseded.any? { |other| key(other.to_s) == name }
  end

  # A page missing a list it should have.
  class LayoutChanged < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new, pages: PAGES)
    @fetcher = fetcher
    @pages = pages
  end

  def crawl(_run)
    stats = @pages.each_with_object({}) do |(url, page), stats|
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = page[:title]
      end
      source.update!(source_kind:) if source.source_kind == "web_page"
      was_held = %w[blocked needs_human].include?(source.crawl_status)
      stats[page[:title]] = DataQuality::Snapshot.take(source, fetcher: @fetcher).to_s
      # Readable again after a block, even unchanged: its lists count again.
      stats[page[:title]] = "readable_again" if was_held && source.reload.crawl_ok?
      next unless source.crawl_ok? && source.content_text.present?

      items = items(source)
      if items.nil?
        source.update!(crawl_status: "needs_human", status_reason: LAYOUT_CHANGED)
        stats[page[:title]] = "layout_changed"
      else
        stats["companies"] = stats.fetch("companies", 0) + items.size
      end
    end
    # A link's description sums up every page, so when one page changed (or
    # stopped being readable), every page is read again: the page that owns
    # a link may not have changed itself.
    pages = Source.where(source_kind:, url: @pages.keys)
    # Which pages are readable and what they hold, against the last finished
    # crawl's: any difference (a page changed, was blocked, came back, or a
    # crawl was cut off before this ran) re-reads every page.
    stats["pages"] = Digest::SHA256.hexdigest(pages.order(:url).pluck(:url, :crawl_status, :content_sha256).to_json)
    last = CrawlRun.where(source_kind:, stage: "crawl", status: "succeeded").order(:id).last&.stats.to_h["pages"]
    unread = pages.where(crawl_status: "ok").where("content_sha256 IS DISTINCT FROM extracted_sha256").exists?
    if unread || stats["pages"] != last
      pages.update_all(extracted_sha256: nil, extracted_rows_sha256: nil)
      # The links' combined descriptions were read from the old pages: their
      # claims not yet decided are withdrawn, and the fresh read proposes them again.
      # Including a replacement held for a person by this plug-in (not one a
      # person reopened or edited, whose notes say otherwise).
      # Never one a person reopened (it keeps its reopenings, as extract does).
      open = Candidate.where(source_id: pages.select(:id), kind: "relationship").where("candidates.reopenings = '[]'::jsonb")
        .where(status: %w[new matched]).or(Candidate.where(source_id: pages.select(:id), kind: "relationship", status: "needs_review", notes: REPLACEMENT)
          .where("candidates.reopenings = '[]'::jsonb"))
      superseded = open.update_all(status: "rejected", notes: SUPERSEDED, updated_at: Time.current)
      stats["superseded"] = superseded if superseded.positive?
    end
    stats
  end

  def extract(source, _run)
    items = items(source) or raise LayoutChanged, "#{LAYOUT_CHANGED} (#{source.url})"

    companies = items.map { |item| { kind: "organization", quote: item.quote, payload: { "name" => item.name } } }
    # One link per company and kind of link, however many lists and pages
    # name it, proposed from the first page (in PAGES order) that names it,
    # with a description summing up every page's lists: a claim from each
    # page would be stopped by #390's guard, since one page's claim would
    # replace what the other's supports. Each page still proposes the company.
    everywhere = other_pages_items(source) + items
    links = items.group_by { |item| [ key(item.name), item.list.relationship_type ] }.filter_map do |group_key, group|
      all = ordered(everywhere.select { |item| [ key(item.name), item.list.relationship_type ] == group_key })
      next unless all.first.page == source.url

      { kind: "relationship", quote: group.first.quote, payload: { "from_organization" => { "name" => DOE },
        "to_organization" => { "name" => group.first.name }, "relationship_type" => group.first.list.relationship_type,
        "description" => all.map(&:description).uniq.join("; ") } }
    end
    companies + links
  end

  # One new page a night (#541): each names at most 11 companies, under the
  # cap of 15 new companies a night; pages read before are never held back.
  def new_sources_per_run = 1

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
    mine = Array(items(source))
    named = mine.select { |item| item.quote == quote.to_s.squish }.map { |item| key(item.name) }
    everywhere = ordered(other_pages_items(source) + mine)
    everywhere.select { |item| named.include?(key(item.name)) }
      .map { |item| [ (@pages.dig(item.page, :title) if item.page != source.url), item.context, item.quote ].compact.join("\n") }
      .uniq.join("\n\n").presence
  end

  def source_facts(source)
    page = @pages[source.url] or return
    "This is the U.S. Department of Energy's own page, \"#{page[:title].delete_prefix('DOE: ')}\". Each list item is a " \
      "company DOE names under the sentence or heading before the list, which says what DOE did with it."
  end

  private
    Item = Data.define(:quote, :name, :list, :context, :description, :page)

    # The other pages' items, from their stored copies (an unreadable one adds nothing).
    def other_pages_items(source)
      # Only pages read cleanly: a blocked or changed-layout page's old copy isn't used.
      Source.where(source_kind:, url: @pages.keys - [ source.url ], crawl_status: "ok").where.not(content_text: nil)
        .flat_map { |other| Array(items(other)) }
    end

    # In PAGES order, then each page's list order.
    def ordered(items)
      lists = @pages.values.flat_map { |page| page[:lists] }
      items.sort_by.with_index { |item, i| [ lists.index(item.list) || lists.size, i ] }
    end

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

        entries.each { |quote| names(quote).each { |name| found << Item.new(quote:, name:, list:, context:, description:, page: source.url) } }
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
