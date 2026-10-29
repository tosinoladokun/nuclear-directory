# NRC's document library (ADAMS), through its Public Search API: licensing
# letters, applications and pre-application documents. Each search in
# SEARCHES is run at most once a day and its documents' catalogue fields
# stored, one JSON line each.
#
# Extract (PM, 29 Oct) reads only documents on a reactor developer's docket:
# a pre-application project (999...) or a new reactor (052...). Routine
# documents about operating plants are left alone. No model is asked.
# - A company in the directory named as the document's author or addressee
#   gets the document as evidence (a company claim that matches it).
# - A name the directory doesn't have becomes a lead for Data Quality
#   (LeadSync's NRC ADAMS feed), never a claim.
# - NRC's letter assigning a project number (a developer entering NRC
#   pre-application) is one news item about that company, for a person.
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

  def initialize(fetcher: DataQuality::Fetcher.new, key: ENV["ADAMS_API_KEY"], today: -> { Date.current }, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @key = key.presence
    @today = today
    @directory = directory
  end

  def crawl(_run)
    return { "skipped" => NO_KEY } unless @key

    SEARCHES.to_h do |name, (query, filters)|
      source = Source.find_or_create_by!(url: "#{API_URL}##{name.parameterize}") do |row|
        row.source_kind = source_kind
        row.title = "NRC ADAMS search: #{name}"
      end
      [ name, DataQuality::Snapshot.claim(source) { search(source, query, filters) }.to_s ]
    end
  end

  NRC = "U.S. Nuclear Regulatory Commission"
  # A pre-application project (999...) or a new reactor's docket (052...).
  DEVELOPER_DOCKET = /\A(?:999|052)\d{5}\z/
  PROJECT_NUMBER = /assignment of project number/i
  # Project-number letters are Tosin's to approve, each (DQ, 29 Oct).
  NEWS_DAYS = 60
  NEWS_PER_READ = 5
  # A lead is a company by its own form (DQ): never a person or a placeholder.
  COMPANY_FORM = /\b(?:Inc|LLC|L\.L\.C|Corp|Corporation|Co|Company|Ltd|Limited|PLC|plc|GmbH|S\.A|AG|LP|L\.P|Group|Holdings)\b\.?/

  def extract(source, _run)
    since = (@today.call - NEWS_DAYS).iso8601
    news = 0
    self.class.developer_documents(source.content_text).flat_map do |line, doc|
      known = self.class.organizations(doc).select { |name| @directory.organization(name:) }
      claims = known.map { |name| { kind: "organization", payload: { "name" => name } } }
      if doc["DocumentTitle"].to_s.match?(PROJECT_NUMBER) && known.any? && doc["DocumentDate"].to_s >= since && news < NEWS_PER_READ
        news += 1
        claims << project_news(doc, known)
      end
      claims.map { |claim| claim.merge(quote: line) }
    end
  end

  # A name worth a lead: a company by its own form, from a document's header (DQ, 29 Oct).
  def self.lead_name?(name) = name.match?(COMPANY_FORM)

  # [[stored line, document]] for documents on a developer's docket.
  def self.developer_documents(text)
    text.to_s.lines(chomp: true).filter_map do |line|
      doc = JSON.parse(line)
      [ line, doc ] if doc.is_a?(Hash) && Array(doc["DocketNumber"]).any? { |docket| docket.to_s.match?(DEVELOPER_DOCKET) }
    rescue JSON::ParserError
      nil
    end
  end

  # The document's authors and addressees other than NRC's own offices.
  def self.organizations(doc)
    (Array(doc["AuthorAffiliation"]) + Array(doc["AddresseeAffiliation"])).map { |name| name.to_s.squish }
      .reject { |name| name.empty? || name.start_with?("NRC") || name.casecmp?(NRC) }.uniq
  end

  def quote_in_source?(source, quote) = quote.present? && source.content_text.to_s.lines(chomp: true).include?(quote.to_s)

  def verification_context(_source, quote) = quote

  def source_facts(_source)
    "This is a list of documents from the U.S. Nuclear Regulatory Commission's document library (ADAMS), one per " \
      "line: accession number, title, date, document type, NRC docket numbers, and the organizations that wrote it " \
      "(AuthorAffiliation) and received it (AddresseeAffiliation). A docket starting 999 is a reactor developer's " \
      "pre-application project; one starting 052 is a new reactor's."
  end

  def max_dropped_share(_source) = 0.0

  private
    def project_news(doc, known)
      { kind: "news_item", payload: {
        "url" => doc["Url"], "title" => doc["DocumentTitle"].to_s.squish, "publisher" => NRC, "published_on" => doc["DocumentDate"],
        "summary" => "NRC assigned a pre-application project number (docket #{Array(doc['DocketNumber']).join(', ')}).",
        "about" => [ { "name" => NRC, "type" => "organization" }, *known.map { |name| { "name" => name, "type" => "organization" } } ] }.compact }
    end

    def search(source, query, filters)
      return :skipped_recent if source.fetched_at&.to_date == Date.current

      since = (@today.call - DAYS).iso8601
      body = { "q" => query, "filters" => [ *filters, { "field" => "DocumentDate", "value" => "(DocumentDate ge '#{since}')" } ],
        "anyFilters" => [], "legacyLibFilter" => false, "mainLibFilter" => true, "sort" => "DocumentDate", "sortDirection" => 1, "skip" => 0 }
      response = @fetcher.post_json(API_URL, body, headers: { "Ocp-Apim-Subscription-Key" => @key })
      attempt = { fetched_at: Time.current, http_status: response.status }
      return failed(source, attempt, response) unless response.kind == :ok

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

    # As Snapshot records a failure: robots' refusal needs a person at once,
    # a block after BLOCKED_STREAK_LIMIT in a row; anything else is retried.
    def failed(source, attempt, response)
      attempt = attempt.merge(status_reason: response.reason)
      case response.kind
      when :blocked
        streak = source.blocked_streak + 1
        source.update!(attempt.merge(blocked_streak: streak,
          crawl_status: streak >= DataQuality::Snapshot::BLOCKED_STREAK_LIMIT ? "needs_human" : "blocked"))
      when :disallowed
        source.update!(attempt.merge(crawl_status: "needs_human"))
      else
        source.update!(attempt)
      end
      response.kind
    end

    # The documents' catalogue fields, one JSON line each; never their text.
    def lines(body)
      json = JSON.parse(body)
      documents = json.is_a?(Array) ? json : Array(json["results"] || json["documents"] || json["value"] || json["data"])
      rows = documents.map { |each| each.is_a?(Hash) && each["document"].is_a?(Hash) ? each["document"] : each }.grep(Hash)
      return "No documents in the answer; keys: #{json.is_a?(Hash) ? json.keys.join(', ') : json.class}" if rows.empty?

      # A document with none of the expected fields keeps its field names, so the reader can be adapted.
      rows.map { |row| (row.slice(*FIELDS).presence || { "unexpected_fields" => row.keys }).to_json }.join("\n")
    end
end
