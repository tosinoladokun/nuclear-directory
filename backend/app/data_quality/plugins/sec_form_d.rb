# SEC Form D notices (#129 part 2): the funding rounds companies report to
# the SEC when they sell securities without registering them. Only the
# companies the directory has an SEC CIK for are read, so every round is
# about a company already here.
#
# Crawl reads each company's filing list from SEC's submissions API
# (data.sec.gov) at most once a day, on an index source of its own that's
# never extracted, keeping only its Form D and D/A filings. Each filing not
# stored yet is fetched once (its primary_doc.xml) and stored as one line of
# its offering fields: form, filing date, accession number, the issuer's CIK
# and name, industry group, securities offered, first sale date, amounts
# offered and sold, what it amends, and whether it's a business combination
# or carries a clarification. Never the people it names (related persons,
# signatures) and never the raw XML. A filing doesn't change once filed, so
# it isn't fetched again.
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
  ARCHIVE_URL = "https://www.sec.gov/Archives/edgar/data/%<cik>d/%<accession>s/primary_doc.xml"
  INDEX_SOURCE_KIND = "sec_submissions"
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

  def crawl(_run)
    stats = Hash.new(0)
    @directory.organizations_with_sec_cik.each do |company|
      index = index_source(company)
      outcome = DataQuality::Snapshot.take(index, fetcher: @fetcher) { |body| filing_lines(body) }
      stats["lists #{outcome}"] += 1
      if outcome == :blocked
        stats["stopped"] = "SEC blocked us"
        break
      end
      next unless index.crawl_ok? && index.content_text

      filings(index.content_text).each do |filing|
        result = store(company, filing)
        stats["filings #{result}"] += 1
        if result == :blocked
          stats["stopped"] = "SEC blocked us"
          return stats
        end
      end
    end
    stats.to_h
  end

  def extract(source, _run)
    fields = fields(source.content_text) or return []
    return [] if amended_later?(fields["accession"])

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
    def index_source(company)
      Source.find_or_create_by!(url: format(SUBMISSIONS_URL, company.sec_cik)) do |source|
        source.source_kind = INDEX_SOURCE_KIND
        source.title = "SEC filings list: #{company.name}"
      end
    end

    # The submissions JSON as one line per Form D or D/A: form, accession, date, document.
    def filing_lines(body)
      recent = JSON.parse(body).dig("filings", "recent") || {}
      Array(recent["form"]).each_index.filter_map do |i|
        next unless FORMS.include?(recent["form"][i])

        [ recent["form"][i], recent["accessionNumber"][i], recent["filingDate"][i], recent["primaryDocument"][i] ].join("\t")
      end.join("\n")
    end

    def filings(text) = text.lines(chomp: true).filter_map { |line| Filing.new(*line.split("\t")) if line.count("\t") == 3 }

    # Each filing is fetched once: it doesn't change after it's filed.
    def store(company, filing)
      url = format(ARCHIVE_URL, cik: company.sec_cik.to_i, accession: filing.accession.delete("-"))
      return :stored_before if Source.where(url:).where.not(content_text: nil).exists?

      response = @fetcher.get(url)
      return response.kind unless response.kind == :ok && !response.truncated

      line = offering_line(response.body, filing) or return :unreadable
      Source.find_or_initialize_by(url:).update!(source_kind:, title: "SEC #{filing.form} #{filing.accession}: #{company.name}",
        content_text: line, content_sha256: Digest::SHA256.hexdigest(line), crawl_status: "ok", http_status: response.status,
        fetched_at: Time.current, published_on: date(filing.filed_on))
      :new
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

    def amended_later?(accession) = stored_filings.any? { |other| other["amends"] == accession }

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
