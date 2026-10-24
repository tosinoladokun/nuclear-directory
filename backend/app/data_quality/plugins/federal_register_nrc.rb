# NRC notices in the Federal Register (#126): the official, dated notices
# the NRC publishes about a named licensee and plant (a construction permit
# application, a license amendment, an exemption, a transfer of control). Each
# becomes a news item claim (#137) about the companies and plants its title
# names, waiting for a person's approval like any claim (Tosin, 21 Oct:
# approve each).
#
# Crawl asks the Federal Register's API once a day, through the shared
# Fetcher, for the NRC's notices of the last WINDOW_DAYS (an index source,
# never extracted). A block is recorded and stops the crawl, never worked
# around. Each notice whose title names its subject the NRC's way,
# "<licensee>; <plant>; <action>" (two or more semicolons), is stored once
# as its own source at its Federal Register page (number, date, title, page,
# abstract), which its claim cites. Notices are told apart by document
# number; a weekly repeat (its abstract says so) of a notice stored in the
# last five weeks isn't stored again.
#
# Extract reads one notice per source. Everything before the action is a
# name the item may be about; match keeps the ones it finds in the directory. A title naming the Commissioners is left out (people's
# names). No model is asked; no fact is proposed from a notice, only the news.
class DataQuality::Plugins::FederalRegisterNrc < DataQuality::Plugin
  API_URL = "https://www.federalregister.gov/api/v1/documents.json"
  PUBLISHER = "Federal Register (NRC)"
  WINDOW_DAYS = 60
  SUMMARY_LENGTH = 400
  FIELDS = %w[document_number publication_date title html_url abstract].freeze
  # Notices about the NRC itself or its forms, never about a licensee.
  NOT_ABOUT_A_LICENSEE = /\A(?:Information Collection|Biweekly Notice)|\bCommissioners?\b/i

  Notice = Data.define(:number, :published_on, :title, :url, :abstract) do
    def line = [ number, published_on, title, url, abstract ].join("\t")
    def segments = title.split(";").map(&:squish).reject(&:empty?)
  end

  def initialize(fetcher: DataQuality::Fetcher.new, today: -> { Date.current })
    @fetcher = fetcher
    @today = today
  end

  # The API's listing: an index, never extracted. Each notice is stored as
  # its own source, at its Federal Register page, which its claim cites.
  INDEX_SOURCE_KIND = "federal_register_index"
  # The NRC's weekly repeats of one notice say so in their abstract.
  WEEKLY_REPEAT = /\b(?:each week|consecutive weeks|weekly notification)/i
  REPEAT_WINDOW = 35

  def crawl(_run)
    index = Source.find_or_create_by!(url: API_URL) do |row|
      row.source_kind = INDEX_SOURCE_KIND
      row.title = "Federal Register: NRC notices"
    end
    outcome = DataQuality::Snapshot.take(index, fetcher: Query.new(@fetcher, query)) { |body| lines(body) }
    stats = { "notices" => outcome.to_s }
    return stats.merge("stopped" => "notices blocked") if outcome == :blocked
    return stats unless index.crawl_ok? && index.content_text.present?

    listed = notices(index.content_text)
    stats.merge("about a licensee" => listed.size, "new" => listed.count { |notice| store(notice) })
  end

  def extract(source, _run)
    notice = parse(source.content_text) or return []
    about = notice.segments[0...-1].flat_map { |name| [ { "name" => name, "type" => "organization" }, { "name" => name, "type" => "facility" } ] }
    [ { kind: "news_item", quote: notice.title, payload: {
      "url" => notice.url, "title" => notice.title, "publisher" => PUBLISHER, "published_on" => notice.published_on,
      "summary" => notice.abstract.presence&.truncate(SUMMARY_LENGTH, separator: " "), "about" => about }.compact } ]
  end

  # One notice per source; notices aging out of the window drop nothing.
  def max_dropped_share(_source) = 0.0

  def quote_in_source?(source, quote) = parse(source.content_text)&.title == quote.to_s.squish

  def verification_context(source, _quote)
    notice = parse(source.content_text) or return
    [ notice.title, notice.published_on, notice.url, notice.abstract ].compact.join("\n")
  end

  def source_facts(_source)
    "These are notices the U.S. Nuclear Regulatory Commission published in the Federal Register. Each title names " \
      "the licensee and the plant the notice is about, then what the NRC did or received."
  end

  # The API takes its query in the URL; the source keeps the plain address.
  Query = Struct.new(:fetcher, :params) do
    def get(url, **options) = fetcher.get("#{url}?#{params}", **options)
  end

  private
    def query
      since = (@today.call - WINDOW_DAYS).iso8601
      [ [ "conditions[agencies][]", "nuclear-regulatory-commission" ], [ "conditions[type][]", "NOTICE" ],
        [ "conditions[publication_date][gte]", since ], [ "per_page", "200" ], [ "order", "newest" ],
        *FIELDS.map { |field| [ "fields[]", field ] } ].then { |pairs| URI.encode_www_form(pairs) }
    end

    # The API's results as one tab-separated line per notice, oldest first.
    def lines(body)
      Array(JSON.parse(body)["results"]).filter_map do |row|
        values = FIELDS.map { |field| row[field].to_s.gsub(/[[:space:]]+/, " ").strip }
        values.join("\t") if values[0].present? && values[3].match?(%r{\Ahttps://www\.federalregister\.gov/})
      end.sort_by { |line| line.split("\t")[1] }.join("\n")
    end

    # Notices about a named licensee in the window, each known by its document number.
    def notices(text)
      since = (@today.call - WINDOW_DAYS).iso8601
      text.to_s.lines(chomp: true).filter_map { |line| parse(line) }
        .select { |notice| notice.title.count(";") >= 2 && notice.published_on.to_s >= since && !notice.title.match?(NOT_ABOUT_A_LICENSEE) }
        .uniq(&:number)
    end

    def parse(line)
      number, date, title, url, abstract = line.to_s.split("\t", 5)
      Notice.new(number:, published_on: date, title:, url:, abstract:) if number.present? && title.present? && url.to_s.start_with?("https://")
    end

    # Stores a notice at its own page, once; a weekly repeat of a notice
    # already stored in the last few weeks isn't stored again. Returns
    # whether it was new.
    def store(notice)
      return false if Source.exists?(url: notice.url)
      return false if repeat?(notice)

      Source.create!(url: notice.url, source_kind:, title: notice.title.truncate(250), crawl_status: "ok", fetched_at: Time.current,
        content_text: notice.line, content_sha256: Digest::SHA256.hexdigest(notice.line), published_on: notice.published_on)
      true
    end

    def repeat?(notice)
      return false unless notice.abstract.to_s.match?(WEEKLY_REPEAT)

      from = (Date.iso8601(notice.published_on) - REPEAT_WINDOW).iso8601
      Source.where(source_kind:, title: notice.title.truncate(250)).where(published_on: from..notice.published_on).exists?
    end
end
