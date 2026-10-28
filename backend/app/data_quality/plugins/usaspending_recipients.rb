# Headquarters of DOE award recipients (gap fill, PM 29 Oct): each
# recipient's own record at USAspending.gov, the federal spending site, which
# gives the address the recipient registered with the government. Its city
# and state become the company's hq_city and hq_state, as a claim a person
# approves.
#
# Crawl reads the recipient record (api/v2/recipient/<id>/) of every
# recipient the DOE awards plug-in has stored, once, and again after
# REFRESH_DAYS, at most PER_NIGHT new ones a night, through the shared
# Fetcher. It stores only "Recipient", "City", "State" and "Country" lines.
# A block stops the run. Extract proposes the city and state for a recipient
# in the United States; a foreign or incomplete address proposes nothing.
class DataQuality::Plugins::UsaspendingRecipients < DataQuality::Plugin
  API_URL = "https://api.usaspending.gov/api/v2/recipient/%s/"
  AWARDS_KIND = "usaspending_doe_awards"
  PER_NIGHT = 15
  REFRESH_DAYS = 90
  # What the address is, shown with every claim (DQ, 29 Oct): for a large
  # firm it may be a branch, not its headquarters.
  ADDRESS_KIND = "Address: registered address (SAM registration)"
  BLOCKED = "USAspending blocked us".freeze

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(_run)
    stats = Hash.new(0)
    due = recipient_ids.filter_map do |id|
      source = Source.find_or_create_by!(url: format(API_URL, id)) do |row|
        row.source_kind = source_kind
        row.title = "USAspending.gov recipient record (registered address, SAM registration)"
      end
      source if source.fetched_at.nil? || source.fetched_at < REFRESH_DAYS.days.ago
    end
    due.sort_by { |source| source.fetched_at || Time.at(0) }.first(PER_NIGHT).each do |source|
      outcome = DataQuality::Snapshot.take(source, fetcher: @fetcher) { |body| address_lines(body) }.to_s
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
    facts = lines.to_h { |line| line.split(": ", 2) }
    return [] unless facts["Country"] == "USA" && facts["City"].present? && facts["State"].to_s.match?(/\A[A-Z]{2}\z/) && facts["Recipient"].present?

    name = awards.display_name(facts["Recipient"])
    quote = lines.select { |line| line.start_with?("Recipient: ", "Address: ", "City: ", "State: ") }.join("\n")
    [ { kind: "organization", quote:, payload: { "name" => name, "aliases" => ([ facts["Recipient"] ] if name != facts["Recipient"]),
      "hq_city" => facts["City"].titleize, "hq_state" => facts["State"] }.compact } ]
  end

  def max_dropped_share(_source) = 1.0

  def quote_in_source?(source, quote)
    lines = source.content_text.to_s.lines(chomp: true)
    quote.to_s.lines(chomp: true).then { |wanted| wanted.any? && (wanted - lines).empty? }
  end

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is a recipient's record at USAspending.gov, the U.S. government's federal spending site: the recipient's " \
      "name and the city, state and country of its registered address (its SAM registration). For a large firm " \
      "that address may be a branch rather than its headquarters."
  end

  private
    def awards = @awards ||= DataQuality::Plugins::UsaspendingDoeAwards.new

    # Every recipient the DOE awards plug-in stored (its CSV's recipient_id column).
    def recipient_ids
      Source.where(source_kind: AWARDS_KIND).where.not(content_text: nil).flat_map do |source|
        CSV.parse(source.content_text, headers: true).filter_map { |row| row["recipient_id"] }
      rescue CSV::MalformedCSVError
        []
      end.uniq.select { |id| id.match?(DataQuality::Plugins::UsaspendingDoeAwards::RECIPIENT_ID) }
    end

    def address_lines(body)
      json = JSON.parse(body)
      location = json["location"] || {}
      [ "Recipient: #{json['name'].to_s.squish}", ADDRESS_KIND, "City: #{location['city_name'].to_s.squish}",
        "State: #{location['state_code']}", "Country: #{location['country_code']}" ].join("\n")
    end
end
