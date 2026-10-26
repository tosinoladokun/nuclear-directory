# ARPA-E's nuclear fission and fusion projects: the companies, labs and
# universities ARPA-E (DOE's Advanced Research Projects Agency–Energy)
# selected, with each award's amount, program and status, from ARPA-E's
# own project index (the JSON its project search reads).
#
# Crawl asks the index once a day, through the shared Fetcher, for the
# projects in its Nuclear Fission and Nuclear Fusion research sub-areas, a
# page of PAGE_SIZE at a time, recording that day's fetch on an index
# source that's never extracted. Each project is stored as its own source,
# at its public project page, as one labelled line (project, organization,
# award, program, status, location, release date); only a new or changed
# line is written. A block stops the crawl.
#
# Extract proposes each organization and an "ARPA-E funds <organization>"
# link whose description states the award as ARPA-E does. A cancelled
# project proposes nothing. No model is asked; a person approves.
# New project pages are read at most NEW_PER_NIGHT a night (#541's cap).
class DataQuality::Plugins::ArpaEProjects < DataQuality::Plugin
  API_URL = "https://arpa-e.energy.gov/JSONAPI/custom/index/project"
  SITE = "https://arpa-e.energy.gov"
  INDEX_SOURCE_KIND = "arpa_e_index"
  FUNDER = "Advanced Research Projects Agency-Energy"
  # "Name (ACRONYM)": the name, with the acronym kept as an alias (DQ).
  ACRONYM = /\A(?<name>.+?)\s*\((?<acronym>[A-Z][A-Za-z0-9&.\-]{1,11})\)\z/
  # ARPA-E's research sub-area ids: Nuclear Fission, Nuclear Fusion.
  SUB_AREAS = { "74" => "nuclear fission", "81" => "nuclear fusion" }.freeze
  PAGE_SIZE = 50
  MAX_PAGES = 10
  NEW_PER_NIGHT = 5
  FIELDS = [ "Project", "Organization", "Award", "Program", "Status", "Location", "Released", "Area", "Funder" ].freeze

  Project = Data.define(:facts) do
    def line = FIELDS.filter_map { |label| "#{label}: #{facts[label]}" if facts[label].present? }.join(" | ")
  end

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(_run)
    index = Source.find_or_create_by!(url: API_URL) do |row|
      row.source_kind = INDEX_SOURCE_KIND
      row.title = "ARPA-E project index (nuclear fission and fusion)"
    end
    stats = {}
    outcome = DataQuality::Snapshot.claim(index) do
      next :skipped_recent if index.fetched_at&.to_date == Date.current

      projects, failure = fetch_all
      # The projects and the day's fetch in one savepoint (claim commits its
      # lock even when the block raises): a failed store keeps nothing, so a
      # rerun fetches and stores them all.
      Source.transaction(requires_new: true) do
        unless failure
          stats["projects"] = projects.size
          stats["new"] = projects.count { |url, line| store(url, line) }
        end
        record(index, failure)
      end
    end
    { "index" => outcome.to_s }.merge(stats).merge(outcome == :blocked ? { "stopped" => "ARPA-E blocked us" } : {})
  end

  def extract(source, _run)
    facts = parse(source.content_text) or return []
    return [] if facts["Status"].to_s.casecmp?("cancelled")

    quote = source.content_text
    recipient = organization(facts["Organization"])
    link = { "from_organization" => { "name" => FUNDER }, "to_organization" => { "name" => recipient["name"] }, "relationship_type" => "funds" }
    # One link per recipient, worded the same from every project page, so
    # two projects for one lab agree; each project is its own award term.
    [
      { kind: "organization", quote:, payload: { "name" => FUNDER, "aliases" => [ "ARPA-E" ] } },
      { kind: "organization", quote:, payload: recipient },
      { kind: "relationship", quote:, payload: link.merge("description" => "Research funding from ARPA-E (nuclear fission and fusion)") },
      { kind: "deal_term", quote:, payload: link.merge("link_type" => "Relationship", "term_type" => "award",
        "external_id" => source.url, "amount_usd" => facts["Award"]&.delete("$,"), "program" => facts["Program"]).compact }
    ]
  end

  def new_sources_per_run = NEW_PER_NIGHT

  # One project per source: a change goes to a person.
  def max_dropped_share(_source) = 1.0

  def quote_in_source?(source, quote) = source.content_text.to_s == quote.to_s

  def verification_context(source, _quote) = source.content_text

  def source_facts(_source)
    "This is one project from ARPA-E's project index, as ARPA-E publishes it: the project's title, the organization " \
      "ARPA-E selected for it, its award amount in US dollars, program, status, location and release date. ARPA-E is " \
      "part of the U.S. Department of Energy and funds the project."
  end

  private
    def organization(name)
      match = ACRONYM.match(name) or return { "name" => name }
      { "name" => match[:name], "aliases" => [ match[:acronym] ] }
    end

    # The index fetch recorded as Snapshot records a page's: block streaks,
    # robots denials, and no HTTP status when nothing answered.
    def record(index, failure)
      attempt = { fetched_at: Time.current, http_status: failure ? failure.status : 200 }
      case failure&.kind
      when nil
        index.update!(attempt.merge(crawl_status: "ok", status_reason: nil, blocked_streak: 0))
        :ok
      when :blocked
        streak = index.blocked_streak + 1
        index.update!(attempt.merge(blocked_streak: streak, status_reason: failure.reason,
          crawl_status: streak >= DataQuality::Snapshot::BLOCKED_STREAK_LIMIT ? "needs_human" : "blocked"))
        :blocked
      when :disallowed
        index.update!(attempt.merge(crawl_status: "needs_human", status_reason: failure.reason))
        :disallowed
      else
        index.update!(attempt.merge(status_reason: failure.reason))
        :error
      end
    end

    # { project page url => stored line } for every fission and fusion
    # project, or [nil, failure response] when a request failed.
    def fetch_all
      projects = {}
      SUB_AREAS.each do |id, area|
        MAX_PAGES.times do |page|
          query = URI.encode_www_form("page[limit]" => PAGE_SIZE, "page[offset]" => page * PAGE_SIZE, "filter[field_reference_technology_sub]" => id)
          response = @fetcher.get("#{API_URL}?#{query}")
          return [ nil, response ] unless response.kind == :ok

          rows = Array(JSON.parse(response.body)["data"])
          rows.each do |row|
            url, line = project_line(row, area)
            projects[url] ||= line if url
          end
          break if rows.size < PAGE_SIZE
        end
      end
      [ projects, nil ]
    rescue JSON::ParserError
      [ nil, DataQuality::Fetcher::Response.new(url: API_URL, kind: :error, status: 200, body: nil, etag: nil, last_modified: nil,
        reason: "ARPA-E answered with something that isn't JSON", block_reference: nil, content_type: nil, truncated: false) ]
    end

    def project_line(row, area)
      fields = row.dig("attributes", "fields") || {}
      path = Array(fields["urls"]).find { |url| url.start_with?("/programs-and-initiatives/") } or return
      organization = Array(fields["organization"]).first&.dig("attributes", "title").to_s.squish
      return if organization.empty? || fields["title"].blank?

      award = fields["award"].to_s.delete(",")
      facts = { "Project" => fields["title"].to_s.squish, "Organization" => organization,
        "Award" => (award.match?(/\A\d+\z/) ? "$#{award.to_i.to_fs(:delimited)}" : nil),
        "Program" => Array(fields["related_programs"]).filter_map { |program| program.dig("fields", "title") }.first,
        "Status" => fields["status"], "Location" => fields["location"], "Released" => fields["release_date"], "Area" => area,
        "Funder" => "#{FUNDER} (ARPA-E)" }
      [ "#{SITE}#{path}", Project.new(facts:).line ]
    end

    # Writes a project's line on its own source when new or changed; true when new.
    def store(url, line)
      source = Source.find_or_initialize_by(url:)
      fresh = source.new_record?
      read = { fetched_at: Time.current, crawl_status: "ok", status_reason: nil, http_status: 200 }
      # Unchanged: today's index still confirms it, so only the read is recorded.
      if !fresh && source.content_text == line
        source.update!(read)
        return false
      end

      source.update!(read.merge(source_kind:, title: "ARPA-E: #{parse(line)['Project'].truncate(200)}", content_text: line,
        content_sha256: Digest::SHA256.hexdigest(line)))
      fresh
    end

    def parse(text)
      facts = text.to_s.split(" | ").to_h { |part| part.split(": ", 2) }
      facts if facts["Project"].present? && facts["Organization"].present?
    end
end
