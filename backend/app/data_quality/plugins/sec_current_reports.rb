# SEC current reports (Form 8-K) of the companies the directory has an SEC
# CIK for: the dated notice a listed company must file within days of a
# material agreement, an acquisition or disposal, or an unregistered sale of
# its shares. An 8-K's text is free prose, so no deal is read from it here:
# each recent 8-K reporting one of ITEMS becomes a news item about the
# company, linked to the filing, for a person to read and record the deal.
#
# Crawl reads each company's filing list from SEC's submissions API
# (data.sec.gov) at most once a day, through the shared Fetcher, on a source
# of its own (the list's address with "#8-K": Form D reads the same list for
# its own forms). It stores a "Company: …" line and one line per 8-K or
# 8-K/A filed in the last WINDOW_DAYS that reports an item in ITEMS. A block
# stops the run. Production only: never fetched from the workstation.
class DataQuality::Plugins::SecCurrentReports < DataQuality::Plugin
  SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK%s.json#8-K"
  ARCHIVE_URL = "https://www.sec.gov/Archives/edgar/data/%<cik>d/%<accession>s/%<document>s"
  FORMS = %w[8-K 8-K/A].freeze
  ITEMS = { "1.01" => "Entry into a Material Definitive Agreement", "1.02" => "Termination of a Material Definitive Agreement",
    "2.01" => "Completion of Acquisition or Disposition of Assets", "3.02" => "Unregistered Sales of Equity Securities" }.freeze
  WINDOW_DAYS = 180
  BLOCKED = "SEC blocked us".freeze

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new, today: -> { Date.current })
    @fetcher = fetcher
    @directory = directory
    @today = today
  end

  def crawl(_run)
    stats = Hash.new(0)
    @directory.organizations_with_sec_cik.each do |company|
      source = Source.find_or_create_by!(url: format(SUBMISSIONS_URL, company.sec_cik)) do |row|
        row.source_kind = source_kind
        row.title = "SEC current reports (8-K): #{company.name}"
      end
      outcome = DataQuality::Snapshot.take(source, fetcher: @fetcher) { |body| report_lines(company, body) }.to_s
      stats[outcome] += 1
      if outcome == "blocked"
        stats["stopped"] = BLOCKED
        break
      end
    end
    stats.to_h
  end

  def extract(source, _run)
    lines = source.content_text.to_s.lines(chomp: true)
    company = lines.first.to_s.delete_prefix("Company: ").presence or return []
    since = @today.call - WINDOW_DAYS
    lines.drop(1).filter_map do |line|
      report = parse(line) or next
      next if report["filed"] < since.iso8601

      items = report["items"].split(", ").filter_map { |item| ITEMS[item] }
      { kind: "news_item", quote: line, payload: {
        "url" => report["document"], "title" => "#{company} 8-K: #{items.join('; ')}", "publisher" => company,
        "published_on" => report["filed"], "summary" => "Form #{report['form']} filed with the SEC on #{report['filed']}, items #{report['items']}.",
        "about" => [ { "name" => company, "type" => "organization" } ] } }
    end
  end

  def max_dropped_share(_source) = 0.0

  def quote_in_source?(source, quote) = quote.present? && source.content_text.to_s.lines(chomp: true).include?(quote.to_s)

  def verification_context(source, quote) = [ source.content_text.to_s.lines.first&.chomp, quote ].compact.join("\n")

  def source_facts(_source)
    "This is a company's list of current reports (Form 8-K) from the SEC's EDGAR system: each line is one report " \
      "the company filed, with its form, filing date, the 8-K item numbers it reports and the filing's address."
  end

  private
    # "Company: …", then "form: 8-K | filed: … | items: 1.01, 9.01 | document: https://…" lines, newest first.
    def report_lines(company, body)
      columns = JSON.parse(body).dig("filings", "recent") || {}
      since = (@today.call - WINDOW_DAYS).iso8601
      reports = Array(columns["form"]).each_index.filter_map do |i|
        next unless FORMS.include?(columns["form"][i]) && columns["filingDate"][i].to_s >= since

        items = columns.fetch("items", [])[i].to_s.split(",").map(&:strip)
        next if (items & ITEMS.keys).empty?

        document = format(ARCHIVE_URL, cik: company.sec_cik.to_i, accession: columns["accessionNumber"][i].delete("-"), document: columns["primaryDocument"][i])
        "form: #{columns['form'][i]} | filed: #{columns['filingDate'][i]} | items: #{items.join(', ')} | document: #{document}"
      end
      [ "Company: #{company.name}", *reports.sort_by { |line| line[/filed: (\S+)/, 1] }.reverse ].join("\n")
    end

    def parse(line)
      fields = line.split(" | ").to_h { |part| part.split(": ", 2) }
      fields if %w[form filed items document].all? { |key| fields[key].present? }
    end
end
