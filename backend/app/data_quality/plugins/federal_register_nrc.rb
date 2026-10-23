# NRC notices in the Federal Register (#126): the official, dated notices
# the NRC publishes about a named licensee and plant (a construction permit
# application, a license amendment, an exemption, a transfer of control). Each
# becomes a news item claim (#137) about the companies and plants its title
# names, waiting for a person's approval like any claim (Tosin, 21 Oct:
# approve each).
#
# Crawl asks the Federal Register's API once a day, through the shared
# Fetcher, for the NRC's notices of the last WINDOW_DAYS, and stores one line
# per notice (number, date, title, page, abstract). A block is recorded and
# stops the crawl, never worked around.
#
# Extract keeps only notices whose title names its subject the NRC's way,
# "<licensee>; <plant>; <action>" (two or more semicolons). Everything before
# the action is a name the item may be about; match keeps the ones it finds
# in the directory. Notices the NRC repeats weekly are proposed once, from
# their first date. A title naming the Commissioners is left out (people's
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

  def crawl(_run)
    source = Source.find_or_create_by!(url: API_URL) do |row|
      row.source_kind = source_kind
      row.title = "Federal Register: NRC notices"
    end
    outcome = DataQuality::Snapshot.take(source, fetcher: Query.new(@fetcher, query)) { |body| lines(body) }
    stats = { "notices" => outcome.to_s }
    return stats.merge("stopped" => "notices blocked") if outcome == :blocked

    stats.merge("about a licensee" => notices(source).size)
  end

  def extract(source, _run)
    taken = decided(source)
    notices(source).reject { |notice| taken.include?(notice.url) || taken.include?(notice.title) }.map do |notice|
      names = notice.segments[0...-1]
      about = names.flat_map { |name| [ { "name" => name, "type" => "organization" }, { "name" => name, "type" => "facility" } ] }
      { kind: "news_item", quote: notice.title, payload: {
        "url" => notice.url, "title" => notice.title, "publisher" => PUBLISHER, "published_on" => notice.published_on,
        "summary" => notice.abstract.presence&.truncate(SUMMARY_LENGTH, separator: " "), "about" => about }.compact }
    end
  end

  # Notices age out of the window: none of that says a news item stopped being true.
  def max_dropped_share(_source) = 0.0

  # The notices extract reads, so the API's own counts and paging don't count as a change.
  def rows_sha256(source)
    list = notices(source)
    Digest::SHA256.hexdigest(list.map(&:line).join("\n")) if list.any?
  end

  def quote_in_source?(source, quote) = notices(source).any? { |notice| notice.title == quote.to_s.squish }

  def verification_context(source, quote)
    notice = notices(source).find { |each| each.title == quote.to_s.squish } or return
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

    # Notices about a named licensee, each title once (its first date), in the window.
    def notices(source)
      since = (@today.call - WINDOW_DAYS).iso8601
      source.content_text.to_s.lines(chomp: true).filter_map do |line|
        number, date, title, url, abstract = line.split("\t", 5)
        Notice.new(number:, published_on: date, title:, url:, abstract:) if title.to_s.count(";") >= 2 && date.to_s >= since
      end.reject { |notice| notice.title.match?(NOT_ABOUT_A_LICENSEE) }.uniq(&:title)
    end

    # Pages and titles of notices a person or match already has: re-reading
    # doesn't send them back, nor a weekly repeat once its first has gone.
    def decided(source)
      source.candidates.where(kind: "news_item").where.not(status: "new")
        .reject { |claim| claim.status_needs_review? && claim.review_origin == "extract" }
        .flat_map { |claim| claim.payload.values_at("url", "title") }.compact.to_set
    end
end
