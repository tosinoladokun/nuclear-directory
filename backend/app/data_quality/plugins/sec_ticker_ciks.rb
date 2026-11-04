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
    @directory.organizations_with_us_ticker_without_cik.each do |_id, name, ticker|
      found = entries[ticker.to_s.upcase]
      unless found&.one?
        stats["not in the list"] += 1
        stats["withdrawn"] += 1 if withdraw("#{TICKERS_URL}##{ticker.upcase}")
        next
      end

      line = found.first.slice("cik_str", "ticker", "title").to_json
      source = Source.find_or_initialize_by(url: "#{TICKERS_URL}##{ticker.upcase}")
      next stats["unchanged"] += 1 if source.persisted? && source.content_text == line

      source.update!(source_kind:, title: "SEC ticker list: #{ticker.upcase} (#{name})", content_text: line,
        content_sha256: Digest::SHA256.hexdigest(line), crawl_status: "ok", fetched_at: Time.current)
      stats["stored"] += 1
    end
    stats.to_h
  rescue JSON::ParserError
    { "ticker list" => "not JSON" }
  end

  def extract(source, _run)
    entry = JSON.parse(source.content_text.to_s) rescue (return [])
    ticker = entry["ticker"].to_s.upcase
    company = @directory.organizations_with_us_ticker_without_cik.find { |_, _, each| each.to_s.upcase == ticker } or return []
    return [] if entry["cik_str"].to_i.zero?

    cik = format("%010d", entry["cik_str"].to_i)
    claim = { kind: "organization", quote: source.content_text, payload: { "name" => company[1], "sec_cik" => cik } }
    # The CIK already on another record (a duplicate, a parent): a person decides, it's never attached there.
    holder = @directory.organization(sec_cik: cik)
    if holder && holder.id != company[0]
      claim.merge!(status: "needs_review", notes: "SEC CIK #{cik} is already on #{holder.name} (id #{holder.id}); check which record it belongs to")
    end
    [ claim ]
  end

  def max_dropped_share(_source) = 1.0

  private
    # SEC's list no longer gives the ticker once: its entry stops being read,
    # and its claims still waiting go to a person (decided ones stay).
    def withdraw(url)
      source = Source.find_by(url:) or return false
      return false unless source.crawl_ok?

      source.update!(crawl_status: "needs_human", status_reason: "SEC's ticker list no longer gives this ticker exactly once")
      source.candidates.where(status: %w[new matched]).update_all(status: "needs_review", updated_at: Time.current)
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
