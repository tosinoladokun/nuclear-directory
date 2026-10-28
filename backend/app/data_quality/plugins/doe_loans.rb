# DOE's loans to nuclear projects, from each project's page on the Office
# of Energy Dominance Financing site (formerly the Loan Programs Office):
# the borrower, the loan's amount, program and closing date, as DOE states
# them in the page's Project Statistics table.
#
# Crawl reads each page in PAGES at most once a day through the shared
# Fetcher and stores only the table's lines ("Owners: …", "Loan Amount: …");
# a block is recorded and skipped, a page without the table goes to a person.
#
# Extract proposes the borrower and a "U.S. Department of Energy funds
# <borrower>" link whose description states the loan as the page does. A
# loan isn't a grant or a funding round, so no deal term is written (the
# deal_term kind has no loan type yet). No model is asked; a person approves.
class DataQuality::Plugins::DoeLoans < DataQuality::Plugin
  DOE = "U.S. Department of Energy"
  # Nuclear projects only; the listing page is drawn by script, so pages are listed here.
  PAGES = {
    "https://www.energy.gov/edf/palisades" => "Palisades",
    "https://www.energy.gov/edf/crane-restart" => "Crane Restart"
  }.freeze
  LABELS = [ "Owners", "Location", "Locations", "EDF Tech Sector", "Loan Program", "Loan Type", "Loan Amount", "Issuance Date" ].freeze
  NO_TABLE = "The page has no Project Statistics table with its owner and loan amount; the page layout may have changed"

  class Unreadable < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new, pages: PAGES)
    @fetcher = fetcher
    @pages = pages
  end

  def crawl(_run)
    @pages.each_with_object({}) do |(url, project), stats|
      source = Source.find_or_create_by!(url:) do |row|
        row.source_kind = source_kind
        row.title = "DOE loan: #{project}"
      end
      take_over(source)
      stats[project] = DataQuality::Snapshot.take(source, fetcher: @fetcher) { |html| stored_text(html) }.to_s
    rescue Unreadable
      source.update!(crawl_status: "needs_human", status_reason: NO_TABLE)
      stats[project] = "needs_human"
    end
  end

  def extract(source, _run)
    facts = parse(source.content_text) or return []
    borrower = facts["Owners"]
    # Every table line the link states: borrower, program, amount, closing date.
    quote = source.content_text.lines.map(&:chomp).select { |line| line.start_with?("Owners: ", "Loan Program: ", "Loan Amount: ", "Issuance Date: ") }.join("\n")
    description = [ "Loan of #{facts['Loan Amount']}", facts["Loan Program"] && "under the #{facts['Loan Program']}",
      facts["Issuance Date"] && "closed #{facts['Issuance Date']}" ].compact.join(", ")
    link = { "from_organization" => { "name" => DOE }, "to_organization" => { "name" => borrower }, "relationship_type" => "funds" }
    amount = amount_usd(facts["Loan Amount"])
    [
      { kind: "organization", quote: "Owners: #{borrower}", payload: { "name" => borrower } },
      { kind: "relationship", quote:, payload: link.merge("description" => description) },
      # The loan itself as a term on that link (#592); its page is its ID.
      ({ kind: "deal_term", quote:, payload: link.merge("link_type" => "Relationship", "term_type" => "loan", "external_id" => source.url,
        "amount_usd" => amount, "program" => facts["Loan Program"]).compact } if amount)
    ].compact
  end

  # One loan per page: a change goes to a person.
  def max_dropped_share(_source) = 1.0

  # Every line of the quote is a line of the stored table.
  def quote_in_source?(source, quote)
    lines = source.content_text.to_s.lines.map(&:chomp)
    quote.to_s.lines.map(&:chomp).then { |wanted| wanted.any? && (wanted - lines).empty? }
  end

  def verification_context(source, _quote) = source.content_text

  def source_facts(source)
    project = @pages[source.url] or return
    "This is the U.S. Department of Energy's page for its loan to the #{project} project: each line is a row of the " \
      "page's Project Statistics table. The Owners are the borrower; DOE made the loan."
  end

  private
    # "$1.52 Billion" => "1520000000", "$1.0 billion", "$850 million"; nil when the page words it otherwise.
    def amount_usd(text)
      match = text.to_s.match(/\A\$\s*([\d,]+(?:\.\d+)?)\s*(billion|million)?\z/i) or return
      (match[1].delete(",").to_d * { "billion" => 10**9, "million" => 10**6 }.fetch(match[2].to_s.downcase, 1)).to_i.to_s
    end

    # A research page already stored at this URL becomes this kind's; its
    # fetch date stays (once a day holds) and its old HTML is cleared.
    def take_over(source)
      return unless source.source_kind == "web_page"

      source.update!(source_kind:, etag: nil, last_modified: nil, content_text: nil, content_sha256: nil,
        extracted_sha256: nil, extracted_rows_sha256: nil)
    end

    # The Project Statistics table as "Label: value" lines.
    def stored_text(html)
      table = Nokogiri::HTML(html.to_s).css("table").find { |each| each.text.include?("Loan Amount") } or raise Unreadable
      lines = table.css("tr").filter_map do |row|
        cells = row.css("th, td").map { |cell| cell.text.gsub(/[[:space:]]+/, " ").strip }.reject(&:empty?)
        label, value = cells.last(2)
        "#{label}: #{value}" if LABELS.include?(label) && value.present?
      end
      raise Unreadable unless lines.any? { |line| line.start_with?("Owners: ") } && lines.any? { |line| line.start_with?("Loan Amount: ") }

      lines.join("\n")
    end

    def parse(text)
      facts = text.to_s.lines.map(&:chomp).to_h { |line| line.split(": ", 2) }
      facts if facts["Owners"].present? && facts["Loan Amount"].present?
    end
end
