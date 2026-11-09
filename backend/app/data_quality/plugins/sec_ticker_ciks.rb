# SEC CIKs for listed companies (PM, 3 Nov): a published company listed on a
# US exchange with no CIK yet gets the CIK SEC's own ticker list gives its
# ticker, as a claim a person approves. With a CIK, gap fill then reads the
# company's SEC record for its headquarters and website (#690, #701).
#
# Crawl reads no new page: it uses SEC's ticker list as the SEC Form D
# plug-in stores it (company_tickers.json, fetched once a day there). For
# each such company whose ticker the list has exactly once, it stores that
# entry as a source of its own (the list's address with "#<TICKER>"),
# written once. Extract proposes the CIK, quoting the entry.
class DataQuality::Plugins::SecTickerCiks < DataQuality::Plugin
  TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"

  def initialize(directory: DataQuality::DirectoryClient.new)
    @directory = directory
  end

  def crawl(_run)
    upstream = Source.find_by(url: TICKERS_URL)
    # Only from a list the Form D plug-in read cleanly: a failed or blocked fetch keeps an old copy.
    return { "ticker list" => "not stored yet" } unless upstream&.content_text.present?
    return { "ticker list" => "last read failed: #{upstream.status_reason}" } unless upstream.crawl_ok? && upstream.status_reason.blank?

    list = upstream.content_text
    entries = JSON.parse(list).values.group_by { |entry| entry["ticker"].to_s.upcase }
    stats = Hash.new(0)
    companies = @directory.organizations_with_us_ticker_without_cik
    # A ticker two directory companies share (different US exchanges) is no one's to claim.
    shared = companies.map { |_, _, ticker| ticker.to_s.upcase }.tally.select { |_, count| count > 1 }.keys
    current = {}
    companies.each do |id, name, ticker|
      ticker = ticker.to_s.upcase
      found = entries[ticker]
      next stats["ticker on several companies"] += 1 if shared.include?(ticker)
      next stats["not in the list"] += 1 unless found&.one?

      cik = found.first["cik_str"].to_i
      holder = cik.positive? && @directory.organization(sec_cik: format("%010d", cik))
      # The CIK already on another record: no claim (approving it would land on that record); a person sees the stat.
      next (stats["CIK already on another record"] += 1) if holder && holder.id != id

      current[ticker] = [ id, name, found.first.slice("cik_str", "ticker", "title").to_json ]
    end
    current.each do |ticker, (id, name, line)|
      source = Source.find_or_initialize_by(url: "#{TICKERS_URL}##{ticker}")
      # The ticker now belongs to another company: the old one's open claims are withdrawn, and the entry is read for the new one.
      if source.persisted? && source.enrich_organization_id && source.enrich_organization_id != id
        withdraw(source)
        source.update!(enrich_organization_id: id, title: "SEC ticker list: #{ticker} (#{name})", crawl_status: "ok", status_reason: nil,
          extracted_sha256: nil, extracted_rows_sha256: nil)
        next stats["new company for ticker"] += 1
      end
      if source.persisted? && source.content_text == line
        # Withdrawn earlier, back unchanged: extracted again (its content digest kept).
        source.update!(crawl_status: "ok", status_reason: nil, extracted_sha256: nil, extracted_rows_sha256: nil) unless source.crawl_ok?
        source.update!(enrich_organization_id: id) unless source.enrich_organization_id
        next stats["unchanged"] += 1
      end

      source.update!(source_kind:, title: "SEC ticker list: #{ticker} (#{name})", content_text: line, enrich_organization_id: id,
        content_sha256: Digest::SHA256.hexdigest(line), crawl_status: "ok", status_reason: nil, fetched_at: Time.current)
      stats["stored"] += 1
    end
    # Any stored entry no longer current (ticker changed or gone, shared, CIK elsewhere) with claims still open: withdrawn.
    Source.where(source_kind:).crawl_ok.find_each do |source|
      next if current.key?(source.url.split("#", 2).last)

      stats["withdrawn"] += 1 if withdraw(source)
    end
    stats.to_h
  rescue JSON::ParserError
    { "ticker list" => "not JSON" }
  end

  def extract(source, _run)
    entry = JSON.parse(source.content_text.to_s) rescue (return [])
    ticker = entry["ticker"].to_s.upcase
    matches = @directory.organizations_with_us_ticker_without_cik.select { |_, _, each| each.to_s.upcase == ticker }
    company = matches.first if matches.one?
    return [] unless company
    return [] if entry["cik_str"].to_i.zero?

    cik = format("%010d", entry["cik_str"].to_i)
    holder = @directory.organization(sec_cik: cik)
    return [] if holder && holder.id != company[0]

    [ { kind: "organization", quote: source.content_text, payload: { "name" => company[1], "sec_cik" => cik } } ]
  end

  def max_dropped_share(_source) = 1.0

  private
    # An entry that no longer applies: it stops being read, and its claims
    # still open go to a person with no recommendation left standing
    # (decided ones stay). Only when something is still open.
    def withdraw(source)
      open = source.candidates.where(status: %w[new matched needs_review])
      return false unless open.exists?

      source.update!(crawl_status: "needs_human", status_reason: "SEC's ticker list no longer gives this company this CIK")
      open.update_all(status: "needs_review", ai_recommendation: nil, dq_recommendation: nil, updated_at: Time.current)
      true
    end

  public

  def quote_in_source?(source, quote) = quote.present? && source.content_text == quote.to_s

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is one entry of the SEC's own list of company tickers (company_tickers.json): the company's ticker, its " \
      "SEC Central Index Key (cik_str) and its name as the SEC files it. The directory company has this ticker on a US exchange."
  end
end
