# SEC Form D notices (#129 part 2): the funding rounds companies report to
# the SEC when they sell securities without registering them. Only the
# companies the directory has an SEC CIK for are read, so every round is
# about a company already here.
#
# Crawl reads each company's filing list from SEC's submissions API
# (data.sec.gov) at most once a day, on an index source of its own that's
# never extracted, keeping only its Form D and D/A filings, and the older
# lists it points to. Each filing not stored yet is fetched through Snapshot
# (once a day at most, a block or failure recorded on it) and stored as one line of
# its offering fields: form, filing date, accession number, the issuer's CIK
# and name, industry group, securities offered, first sale date, amounts
# offered and sold, what it amends, and whether it's a business combination
# or carries a clarification. Never the people it names (related persons,
# signatures) and never the raw XML. A filing doesn't change once filed, so
# it isn't fetched again. Once a later filing of a round is stored, the
# round's earlier claims still waiting are withdrawn.
#
# Extract turns each stored filing into one funding round (a deal term on the
# company, #397), identified by the accession number of the round's first
# filing: a Form D/A restates the whole form and names what it amends, so it
# lands on the same round. Only the latest stored filing of a round is
# proposed. A filing with no amount sold proposes nothing; a business
# combination or a clarification note is held for a person. No model is
# asked; a person approves every round.
class DataQuality::Plugins::SecFormD < DataQuality::Plugin
  SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK%s.json"
  OLDER_URL = "https://data.sec.gov/submissions/%<name>s"
  ARCHIVE_URL = "https://www.sec.gov/Archives/edgar/data/%<cik>d/%<accession>s/primary_doc.xml"
  INDEX_SOURCE_KIND = "sec_submissions"
  # SEC's own ticker-to-CIK list, kept as a source so Data Quality can cite
  # it for a company's CIK (read by ticker from the company's own IR page).
  TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"
  FORMS = %w[D D/A].freeze
  NOT_SOLD = "it reports no amount sold"
  SECURITIES = { "isEquityType" => "equity", "isDebtType" => "debt", "isOptionToAcquireType" => "options",
    "isSecurityToBeAcquiredType" => "securities to be acquired", "isPooledInvestmentFundType" => "pooled fund interests",
    "isTenantInCommonType" => "tenant-in-common", "isMineralPropertyType" => "mineral property", "isOtherType" => "other" }.freeze
  FIELDS = [ "form", "filed", "accession", "issuer CIK", "issuer", "industry group", "securities", "first sale", "amount offered",
    "amount sold", "amends", "business combination", "clarification" ].freeze

  Filing = Data.define(:form, :accession, :filed_on, :document)

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @directory = directory
  end

  # A filing whose notice has no offering fields to store.
  class Unreadable < StandardError; end
  BLOCKED = "SEC blocked us".freeze

  def crawl(_run)
    stats = Hash.new(0)
    stats["ticker list"] = DataQuality::Snapshot.take(tickers_source, fetcher: @fetcher).to_s
    return stats.merge("stopped" => BLOCKED).to_h if stats["ticker list"] == "blocked"

    @directory.organizations_with_sec_cik.each do |company|
      filings = filing_list(company, stats) or return stats.merge("stopped" => BLOCKED).to_h

      filings.each do |filing|
        result = store(company, filing)
        stats["filings #{result}"] += 1
        return stats.merge("stopped" => BLOCKED).to_h if result == :blocked
      end
    end
    stats["superseded"] = supersede_earlier_filings
    stats.reject { |key, count| key == "superseded" && count.zero? }.to_h
  end

  def extract(source, _run)
    fields = fields(source.content_text) or return []
    return [] unless latest_of_round?(fields)

    sold = amount(fields["amount sold"])
    return [] unless sold&.positive?

    [ { kind: "deal_term", quote: source.content_text, payload: {
      "organization" => { "name" => fields["issuer"], "sec_cik" => fields["issuer CIK"] }, "link_type" => "Organization",
      "term_type" => "funding_round", "external_id" => first_accession(fields), "amount_usd" => sold.to_s("F"),
      "amount_offered_usd" => amount(fields["amount offered"])&.to_s("F"), "starts_on" => date(fields["first sale"]) }.compact } ]
  end

  # One filing per source: a round isn't dropped because a later filing replaced it.
  def max_dropped_share(_source) = 0.0

  def quote_in_source?(source, quote) = quote.present? && source.content_text == quote

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is one Form D notice a company filed with the U.S. Securities and Exchange Commission, as the company " \
      "reported it: an offering of securities sold without registration. \"amount sold\" is what it had sold by the " \
      "filing date; a Form D/A restates the whole notice and names the filing it amends."
  end

  # A person decides a round whose notice says it isn't an ordinary raise.
  def hold_for_review(candidate)
    fields = fields(candidate.quote) or return
    if fields["business combination"] == "yes"
      "The notice says it's part of a business combination (a merger or acquisition), not a funding round on its own"
    elsif fields["clarification"].present?
      "The notice adds a clarification of its amounts: #{fields['clarification'].truncate(200)}"
    end
  end

  private
    def tickers_source
      Source.find_or_create_by!(url: TICKERS_URL) do |source|
        source.source_kind = INDEX_SOURCE_KIND
        source.title = "SEC: company tickers and CIKs"
      end
    end

    def index_source(company)
      Source.find_or_create_by!(url: format(SUBMISSIONS_URL, company.sec_cik)) do |source|
        source.source_kind = INDEX_SOURCE_KIND
        source.title = "SEC filings list: #{company.name}"
      end
    end

    # A filing list as one line per Form D or D/A (form, accession, date,
    # document), then one line per older list it points to ("file", name).
    # The main list keeps its filings under filings.recent; an older list is
    # just the columns.
    def filing_lines(body)
      json = JSON.parse(body)
      columns = json.dig("filings", "recent") || json
      lines = Array(columns["form"]).each_index.filter_map do |i|
        next unless FORMS.include?(columns["form"][i])

        [ columns["form"][i], columns["accessionNumber"][i], columns["filingDate"][i], columns["primaryDocument"][i] ].join("\t")
      end
      older = Array(json.dig("filings", "files")).filter_map { |file| "file\t#{file['name']}" if file["name"].to_s.match?(/\ACIK\d{10}-submissions-\d+\.json\z/) }
      (lines + older).join("\n")
    end

    def filings(text) = text.lines(chomp: true).filter_map { |line| Filing.new(*line.split("\t")) if line.count("\t") == 3 }

    # A company's Form D and D/A filings, from its filing list and the older
    # lists it points to (filings.files), each read at most once a day. nil
    # when SEC blocked us.
    def filing_list(company, stats)
      index = index_source(company)
      outcome = DataQuality::Snapshot.take(index, fetcher: @fetcher) { |body| filing_lines(body) }
      stats["lists #{outcome}"] += 1
      return if outcome == :blocked
      return [] unless index.crawl_ok? && index.content_text

      older = index.content_text.lines(chomp: true).filter_map { |line| line.delete_prefix("file\t") if line.start_with?("file\t") }
      texts = older.map do |name|
        source = Source.find_or_create_by!(url: format(OLDER_URL, name:)) do |row|
          row.source_kind = INDEX_SOURCE_KIND
          row.title = "SEC filings list (older): #{company.name}"
        end
        outcome = DataQuality::Snapshot.take(source, fetcher: @fetcher) { |body| filing_lines(body) }
        stats["lists #{outcome}"] += 1
        return if outcome == :blocked

        source.content_text.to_s
      end
      filings([ index.content_text, *texts ].join("\n")).uniq(&:accession)
    end

    # Each filing is stored once, through Snapshot (its daily guard, and a
    # block or failure recorded on it): a filing doesn't change after it's filed.
    def store(company, filing)
      url = format(ARCHIVE_URL, cik: company.sec_cik.to_i, accession: filing.accession.delete("-"))
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = "SEC #{filing.form} #{filing.accession}: #{company.name}"
        row.published_on = date(filing.filed_on)
      end
      return :stored_before if source.content_text.present?

      result = DataQuality::Snapshot.take(source, fetcher: @fetcher) { |body| offering_line(body, filing) or raise Unreadable }
      result == :changed ? :new : result
    rescue Unreadable
      source.update!(crawl_status: "needs_human", status_reason: "SEC's notice has no offering fields to read")
      :unreadable
    end

    # A round's earlier filings' claims still waiting are withdrawn once a
    # later filing of the round is stored (as an older EIA file's are): only
    # the latest filing's values can be approved. One a person is already
    # reviewing keeps its place, with a note.
    def supersede_earlier_filings
      @stored_filings = nil
      latest = stored_filings.group_by { |fields| first_accession(fields) }.transform_values { |group| group.max_by { |fields| order(fields) } }
      earlier = Source.where(source_kind:).where.not(content_text: nil).reject do |source|
        fields = fields(source.content_text)
        fields.nil? || latest[first_accession(fields)]&.fetch("accession") == fields["accession"]
      end
      return 0 if earlier.empty?

      Candidate.transaction do
        waiting = Candidate.where(source_id: earlier.map(&:id), kind: "deal_term")
        waiting.where(status: "needs_review").where.not("notes LIKE ?", "%A later filing of this round exists%")
          .update_all([ "notes = COALESCE(notes || '. ', '') || ?, updated_at = ?", "A later filing of this round exists", Time.current ])
        waiting.where(status: %w[new matched]).update_all(status: "rejected", notes: "Superseded by a later filing of this round", updated_at: Time.current)
      end
    end

    # The notice's offering fields as one labelled line; never its people.
    def offering_line(xml, filing)
      doc = Nokogiri::XML(xml.to_s)
      doc.remove_namespaces!
      offering = doc.at_xpath("/edgarSubmission/offeringData") or return
      text = ->(path) { offering.at_xpath(path)&.text.to_s.squish.presence }
      securities = SECURITIES.filter_map { |tag, words| words if text.("typesOfSecuritiesOffered/#{tag}") == "true" }
      values = [ filing.form, filing.filed_on, filing.accession, doc.at_xpath("/edgarSubmission/primaryIssuer/cik")&.text.to_s.strip,
        doc.at_xpath("/edgarSubmission/primaryIssuer/entityName")&.text.to_s.squish, text.("industryGroup/industryGroupType"),
        securities.join(", ").presence, text.("typeOfFiling/dateOfFirstSale/value") || text.("typeOfFiling/dateOfFirstSale/yetToOccur") && "yet to occur",
        dollars(text.("offeringSalesAmounts/totalOfferingAmount")), dollars(text.("offeringSalesAmounts/totalAmountSold")),
        text.("typeOfFiling/newOrAmendment/previousAccessionNumber"),
        text.("businessCombinationTransaction/isBusinessCombinationTransaction") == "true" ? "yes" : "no",
        [ text.("offeringSalesAmounts/clarificationOfResponse"), text.("businessCombinationTransaction/clarificationOfResponse") ].compact.join(" ").presence ]
      return if values[3].blank? || values[4].blank?

      FIELDS.zip(values).map { |label, value| "#{label}: #{value.to_s.delete('|').presence || '-'}" }.join(" | ")
    end

    def dollars(value)
      return value unless value&.match?(/\A\d+(\.\d+)?\z/)

      "$#{BigDecimal(value).to_i.to_fs(:delimited)}"
    end

    # { label => value } from a stored line, or nil when it isn't one.
    def fields(text)
      pairs = text.to_s.split(" | ").map { |part| part.split(": ", 2) }
      return unless pairs.map(&:first) == FIELDS

      pairs.to_h { |label, value| [ label, value == "-" ? nil : value ] }
    end

    def amount(text)
      digits = text.to_s.delete("$,")
      BigDecimal(digits) if digits.match?(/\A\d+(\.\d+)?\z/)
    end

    def date(text)
      Date.iso8601(text.to_s).iso8601
    rescue Date::Error
      nil
    end

    def stored_filings
      @stored_filings ||= Source.where(source_kind:).where.not(content_text: nil).filter_map { |source| fields(source.content_text) }
    end

    # The round's newest stored filing, by filing date then accession (two
    # D/As can amend the same filing).
    def latest_of_round?(fields)
      root = first_accession(fields)
      latest = stored_filings.select { |other| first_accession(other) == root }.max_by { |other| order(other) }
      latest.nil? || latest["accession"] == fields["accession"]
    end

    def order(fields) = [ fields["filed"].to_s, fields["accession"].to_s ]

    # A D/A names the filing it amends; that one may amend another. The
    # round is known by its first filing.
    def first_accession(fields)
      seen = [ fields["accession"] ]
      while (previous = fields["amends"]) && !seen.include?(previous)
        seen << previous
        fields = stored_filings.find { |other| other["accession"] == previous } or return previous
      end
      fields["accession"]
    end
end
