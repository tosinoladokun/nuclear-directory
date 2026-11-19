# Base class for source plug-ins. Each source_kind (e.g. nrc_reactor_list)
# has one plug-in under app/data_quality/plugins, which knows how to crawl
# and extract that kind of source. Match and verify are shared.
#
# The plug-in for a source_kind is found by name:
#   "nrc_reactor_list" => DataQuality::Plugins::NrcReactorList
class DataQuality::Plugin
  class UnknownSourceKind < StandardError; end

  def self.for(source_kind)
    "DataQuality::Plugins::#{source_kind.to_s.camelize}".safe_constantize&.new or
      raise UnknownSourceKind, "No plug-in for source kind #{source_kind.inspect}"
  end

  def source_kind = self.class.name.demodulize.underscore

  # Fetch this plug-in's sources and store each snapshot on a Source row
  # (content_text, content_sha256, crawl_status, fetched_at).
  # Returns a stats hash for the crawl run.
  def crawl(run)
    raise NotImplementedError, "#{self.class} must implement #crawl"
  end

  # Turn one crawled Source into candidate facts. Returns an array of
  # { kind:, payload:, quote: } hashes; quote is the supporting text.
  def extract(source, run)
    raise NotImplementedError, "#{self.class} must implement #extract"
  end

  # A hash of the rows extract reads from this snapshot (#240). When it's
  # the same as last time, the source says nothing new and isn't extracted
  # again. Default: the stored content's hash, for sources stored as just
  # their rows. A plug-in that stores a whole page (with a date stamp, say)
  # hashes only its table.
  def rows_sha256(source) = source.content_sha256

  # When a complete read of this source no longer lists a fact it
  # supported (#240): the payload a review item proposes (e.g. NRC's
  # operating list dropping a unit suggests it shut down) and why, or nil to
  # keep the fact's last payload and just ask. Returns [payload, note] or nil.
  def dropped(_kind) = nil

  # How many sources never read before one run extracts (#513), so a new
  # source's first batch reaches people a night at a time; the rest wait for
  # the next nights. nil: no cap. Sources read before are never held back.
  def new_sources_per_run = nil

  # The order new sources are taken under that cap; first come first.
  def new_source_order(sources) = sources.sort_by(&:id)

  # The largest share of a source's supported facts one complete read may
  # drop and still be flagged (#240). More than that looks like a broken
  # page rather than real changes, and flags nothing. Default: a quarter. A
  # plug-in whose sources each hold a few facts, checked elsewhere as
  # complete, can allow more; a dropped fact is only ever a review item.
  def max_dropped_share(_source) = 0.25

  # The ids of earlier editions of the same document (#382), oldest first:
  # an annual file whose every year is its own source. A newer edition
  # isn't "another page" of a fact an older one cites (Match.other_page_on),
  # and a fact an older edition supported counts as this one's for the
  # dropped check (Match#flag_dropped). Default: none.
  def earlier_editions(_source) = []

  # Whether an unplaced claim (no record, or not yet matched) makes a read
  # incomplete for the dropped check (Match#flag_dropped). Default: every
  # one does. A plug-in whose file always lists things the directory doesn't
  # have (EIA's owners of plants not listed yet) says no for those, as they
  # can't hide a dropped fact.
  def blocks_dropped_check?(_candidate) = true

  # Verify (#15) asks these two questions of the plug-in, because only it
  # knows how its quotes were taken from the source.

  # Does the quote really appear in the source's stored content? Catches
  # made-up quotes before any model is asked. Default: in the page's
  # visible text, ignoring tags and spacing.
  def quote_in_source?(source, quote)
    quote.present? && visible_text(source).include?(quote.squish)
  end

  # What the verifier model reads to check a claim. Default: the passage
  # around the quote, about 3,000 characters.
  def verification_context(source, quote)
    text = visible_text(source)
    at = text.index(quote.to_s.squish) || 0
    text[[ at - 1_500, 0 ].max, 3_000 + quote.to_s.length]
  end

  # What the source states as a whole, true of every row in it, which a
  # single row doesn't repeat (e.g. "every row is an operating US power
  # reactor"). The verifier treats it as part of every excerpt. Only facts
  # the source itself plainly states, never outside knowledge. Default: none.
  def source_facts(_source) = nil

  # Why a person must decide this claim whatever the verifier would say
  # (e.g. NRC lists a unit as decommissioning while its owner plans a
  # restart), or nil. Verify checks it with its other code checks, after
  # match, so the claim keeps its record and its links still resolve.
  # Default: none.
  def hold_for_review(_candidate) = nil

  private
    # The source's text as a reader sees it: tags dropped for HTML (and
    # script, style, template and noscript contents, which nobody reads), with a
    # space between pieces so table cells don't run together ("Vogtle 3",
    # "05200025", not "Vogtle 305200025"), spacing tidied. Cached per snapshot.
    # Only the last source's text is kept (Infra, 15 Nov: an out-of-memory
    # kill; a plug-in reading thousands of pages a night held every one).
    def visible_text(source)
      key = [ source.id, source.content_sha256 ]
      @visible_text = nil unless @visible_text&.key?(key)
      (@visible_text ||= {})[key] ||= begin
        content = source.content_text.to_s
        if content.lstrip.first(200).match?(/<(!doctype html|html|head|body|table)\b/i)
          doc = Nokogiri::HTML(content)
          content = doc.xpath("//body//text()[not(ancestor::script or ancestor::style or " \
            "ancestor::template or ancestor::noscript)]").map(&:text).join(" ").squish
          # A thin page (a JavaScript site) also reads what it carries for
          # machines: its descriptions and embedded data (#802). Never runs it.
          content = [ content, *page_data_text(doc) ].join(" ") if content.length < THIN_PAGE
        end
        content.squish
      end
    end

    # A page's visible body text alone, without its page data.
    def body_text(source)
      content = source.content_text.to_s
      return content.squish unless content.lstrip.first(200).match?(/<(!doctype html|html|head|body|table)\b/i)

      Nokogiri::HTML(content).xpath("//body//text()[not(ancestor::script or ancestor::style or " \
        "ancestor::template or ancestor::noscript)]").map(&:text).join(" ").squish
    end

    PAGE_DATA_CHARS = 20_000
    PAGE_DATA_SCRIPT_BYTES = 1.megabyte

    # Pages with less visible text than this also read their page data.
    THIN_PAGE = 600

    # The text a page carries for machines: meta, Open Graph and Twitter
    # descriptions, JSON-LD names and descriptions, and the text values of
    # framework data (__NEXT_DATA__, Nuxt). No code is run. At most 20,000
    # characters, each value once.
    def page_data_text(doc)
      metas = doc.css("meta[name='description'], meta[property='og:description'], meta[name='twitter:description'], " \
        "meta[property='og:title'], meta[name='twitter:title'], meta[property='og:site_name']").filter_map { |meta| meta["content"].to_s.squish.presence }
      data = []
      doc.css("script[type='application/ld+json'], script#__NEXT_DATA__, script#__NUXT_DATA__").each do |script|
        # Never a huge one (Infra: memory), and no more once there's enough.
        break if data.sum(&:length) >= PAGE_DATA_CHARS
        next if script.text.bytesize > PAGE_DATA_SCRIPT_BYTES

        text_values(JSON.parse(script.text), data)
      rescue JSON::ParserError
        next
      end
      (metas + data).uniq.join(" ").first(PAGE_DATA_CHARS).split(" ")
    end

    # Human-readable strings in parsed JSON: a few words or more, never code, URLs or ids.
    def text_values(value, out = [])
      case value
      when Hash then value.each_value { |each| break if out.sum(&:length) >= PAGE_DATA_CHARS; text_values(each, out) }
      when Array then value.each { |each| break if out.sum(&:length) >= PAGE_DATA_CHARS; text_values(each, out) }
      when String
        text = value.squish
        out << text if text.length.between?(12, 2_000) && text.count(" ") >= 2 && !text.match?(/\A(?:https?:|\/|[\[{<])/) && !text.include?("function")
      end
      out
    end
end
