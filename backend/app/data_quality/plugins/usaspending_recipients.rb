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
  AWARDS_INDEX_KIND = "usaspending_api"
  PER_NIGHT = 15
  REFRESH_DAYS = 90
  # What the address is, shown with every claim (DQ, 29 Oct): for a large
  # firm it may be a branch, not its headquarters.
  ADDRESS_KIND = "Address: registered address (SAM registration)"
  BLOCKED = "USAspending blocked us".freeze

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @directory = directory
  end

  def crawl(_run)
    # A block on USAspending today (the awards search or a record): stop before asking again.
    today = Time.current.all_day
    if Source.where(source_kind: [ AWARDS_INDEX_KIND, source_kind ], crawl_status: "blocked", fetched_at: today).exists?
      return { "stopped" => BLOCKED }
    end

    stats = Hash.new(0)
    due = recipient_ids.filter_map do |id|
      source = Source.find_or_create_by!(url: format(API_URL, id)) do |row|
        row.source_kind = source_kind
        row.title = "USAspending.gov recipient record (registered address, SAM registration)"
      end
      source if due?(source)
    end
    # PER_NIGHT a day in all, a same-day rerun included.
    room = PER_NIGHT - Source.where(source_kind:, fetched_at: today).count
    due.sort_by { |source| source.fetched_at || Time.at(0) }.first([ room, 0 ].max).each do |source|
      # A full read, not "not modified", when the stored lines lack the parent.
      source.update!(etag: nil, last_modified: nil) if source.content_text.present? && !source.content_text.include?("\nParent: ")
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
    # A recipient under another parent registers a subsidiary's or branch's
    # address, not the company's headquarters (DQ, 30 Oct).
    # A record stored before the parent was kept waits for its re-read.
    return [] unless facts.key?("Parent")
    return [] if facts["Parent"].present? && !same_name?(facts["Parent"], facts["Recipient"])

    name = awards.display_name(facts["Recipient"])
    # Only a missing headquarters is filled: a registered address never replaces one (DQ, 30 Oct).
    # As match finds it: by name or alias, else a unique brand match.
    company = @directory.organization(name:) || @directory.organization(name: facts["Recipient"]) ||
      @directory.same_brand_organizations(name).then { |brand| brand.first if brand.one? }
    return [] if company && @directory.organization_hq_city(company.id)
    quote = lines.select { |line| line.start_with?("Recipient: ", "Address: ", "City: ", "State: ") }.join("\n")
    # USAspending's spelling as an alias only when the company doesn't answer to it yet, in any case (DQ, 31 Oct).
    alias_needed = name != facts["Recipient"] && company.nil?
    [ { kind: "organization", quote:, payload: { "name" => name, "aliases" => ([ facts["Recipient"] ] if alias_needed),
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
    # Never read; or read well and REFRESH_DAYS old; or a failed read
    # (nothing stored) from before today.
    def due?(source)
      return true if source.fetched_at.nil?
      # Stored before the parent was kept (30 Oct): read again.
      return true if source.content_text.present? && !source.content_text.include?("\nParent: ")
      return source.fetched_at < REFRESH_DAYS.days.ago if source.crawl_ok? && source.content_text.present?

      source.fetched_at < Time.current.beginning_of_day
    end

    def awards = @awards ||= DataQuality::Plugins::UsaspendingDoeAwards.new

    def same_name?(one, other) = awards.display_name(one).casecmp?(awards.display_name(other))

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
      [ "Recipient: #{json['name'].to_s.squish}", "Parent: #{json['parent_name'].to_s.squish}", ADDRESS_KIND, "City: #{location['city_name'].to_s.squish}",
        "State: #{location['state_code']}", "Country: #{location['country_code']}" ].join("\n")
    end
end
