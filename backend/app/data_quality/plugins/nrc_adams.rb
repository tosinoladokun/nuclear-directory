# NRC's document library (ADAMS), through its Public Search API: licensing
# letters, applications and pre-application documents. A first read (PM,
# 28 Oct): each search in SEARCHES is run at most once a day and its
# documents' catalogue fields stored, one JSON line each, so the reader can
# be written against real results. It proposes nothing yet.
#
# The API needs a subscription key (ADAMS_API_KEY, sent as NRC asks in the
# Ocp-Apim-Subscription-Key header, never stored). Without one the crawl
# does nothing. A block or a refused key is recorded on the search's source.
class DataQuality::Plugins::NrcAdams < DataQuality::Plugin
  API_URL = "https://adams-api.nrc.gov/aps/api/search"
  FIELDS = %w[AccessionNumber DocumentTitle DocumentDate DocumentType DocketNumber AuthorAffiliation AddresseeAffiliation Url].freeze
  DAYS = 14
  # Name => [query text, extra filters]; every search is limited to the last DAYS days, newest first.
  SEARCHES = {
    "pre-application" => [ "\"pre-application\"", [] ],
    "advanced reactor licensing" => [ "\"advanced reactor\" OR \"construction permit\" OR \"operating license application\"", [] ]
  }.freeze
  NO_KEY = "no ADAMS_API_KEY set"

  def initialize(fetcher: DataQuality::Fetcher.new, key: ENV["ADAMS_API_KEY"], today: -> { Date.current })
    @fetcher = fetcher
    @key = key.presence
    @today = today
  end

  def crawl(_run)
    return { "skipped" => NO_KEY } unless @key

    SEARCHES.to_h do |name, (query, filters)|
      source = Source.find_or_create_by!(url: "#{API_URL}##{name.parameterize}") do |row|
        row.source_kind = source_kind
        row.title = "NRC ADAMS search: #{name} (first read)"
      end
      [ name, DataQuality::Snapshot.claim(source) { search(source, query, filters) }.to_s ]
    end
  end

  # A first read: nothing proposed until the reader is written from what's stored.
  def extract(_source, _run) = []

  def max_dropped_share(_source) = 0.0

  private
    def search(source, query, filters)
      return :skipped_recent if source.fetched_at&.to_date == Date.current

      since = (@today.call - DAYS).iso8601
      body = { "q" => query, "filters" => [ *filters, { "field" => "DocumentDate", "value" => "(DocumentDate ge '#{since}')" } ],
        "anyFilters" => [], "legacyLibFilter" => false, "mainLibFilter" => true, "sort" => "DocumentDate", "sortDirection" => 1, "skip" => 0 }
      response = @fetcher.post_json(API_URL, body, headers: { "Ocp-Apim-Subscription-Key" => @key })
      attempt = { fetched_at: Time.current, http_status: response.status }
      unless response.kind == :ok
        streak = response.kind == :blocked ? source.blocked_streak + 1 : source.blocked_streak
        source.update!(attempt.merge(status_reason: response.reason, blocked_streak: streak,
          crawl_status: response.kind == :blocked ? "blocked" : source.crawl_status))
        return response.kind
      end

      text = lines(response.body)
      sha = Digest::SHA256.hexdigest(text)
      changed = sha != source.content_sha256
      source.update!(attempt.merge(crawl_status: "ok", status_reason: nil, blocked_streak: 0)
        .merge(changed ? { content_text: text, content_sha256: sha } : {}))
      changed ? :changed : :unchanged
    rescue JSON::ParserError
      source.update!(fetched_at: Time.current, crawl_status: "needs_human", status_reason: "ADAMS answered with something that isn't JSON")
      :needs_human
    end

    # The documents' catalogue fields, one JSON line each; never their text.
    def lines(body)
      json = JSON.parse(body)
      documents = json.is_a?(Array) ? json : Array(json["results"] || json["documents"] || json["value"] || json["data"])
      rows = documents.map { |each| each.is_a?(Hash) && each["document"].is_a?(Hash) ? each["document"] : each }.grep(Hash)
      return "No documents in the answer; keys: #{json.is_a?(Hash) ? json.keys.join(', ') : json.class}" if rows.empty?

      rows.map { |row| row.slice(*FIELDS).to_json }.join("\n")
    end
end
