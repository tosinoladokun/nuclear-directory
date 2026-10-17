# NRC's list of power reactor sites undergoing decommissioning (#274), for
# the Waste and decommissioning bucket and the plants that no longer run.
#
# Crawl fetches the list page, then NRC's page for each site it links to
# (about 20), under the shared Fetcher's rules: once a day per URL,
# conditional requests, honest user agent, robots.txt, no retries. A block
# is recorded and stops the crawl; nothing is worked around.
#
# Extract, from the list: one unit per row (docket, `power_reactor`, status
# `decommissioning` as the list states, city and state from its Location),
# quoting the row, and a site for a plant listed with several units (Indian
# Point, San Onofre), so it counts as one plant. No model is asked.
# From each site page: the companies NRC says hold the license, read by the
# extractor model (Licensees) and checked here: a quote that isn't on the
# page, or doesn't name the company, sends the claim to review. Each
# licensee gives a company, an operates or owns link to every unit the page
# covers, and, only where the page says it took over the license to
# decommission the site, the waste_decommissioning category with that quote.
#
# Match, verify and a human's approval are shared. Units NRC lists as
# decommissioning whose owners plan a restart (RESTART_PLANS) are proposed
# as NRC states them, and verify holds them for a person with a note
# (Tosin: a restart plan is a note, never a status). So is TMI-2
# (PLACE_BY_HAND), which must never go under Crane.
class DataQuality::Plugins::NrcDecommissioning < DataQuality::Plugin
  LIST_URL = "https://www.nrc.gov/facilities-safety/facility-finder/decommissioning/power-reactor"
  TABLE_MISSING = "Couldn't find the decommissioning table; the page layout may have changed"
  ROLE = "waste_decommissioning"
  # NRC's spelling where it doesn't name the unit the way its operating list
  # does. Crane and Duane Arnold Energy Center are sites in the directory, so
  # "Crane 1" and "Duane Arnold 1" go under them as units (the site never
  # takes a unit's docket); NRC's spelling stays as an alias.
  UNIT_NAMES = { "05000289" => "Crane 1", "05000331" => "Duane Arnold 1" }.freeze
  # Units on the list that their owners plan to restart, with the owner's
  # own announcement. Proposed as decommissioning, held for a person.
  # Approving one fills its site's blank status, so the site shows
  # Decommissioning too, as NRC says.
  RESTART_PLANS = {
    "05000289" => [ "Constellation plans to restart this unit as the Crane Clean Energy Center",
      "https://www.constellationenergy.com/news/2024/Constellation-to-Launch-Crane-Clean-Energy-Center-Restoring-Jobs-and-Carbon-Free-Power-to-The-Grid.html" ],
    "05000331" => [ "NextEra Energy plans to restart Duane Arnold",
      "https://www.investor.nexteraenergy.com/news-and-events/news-releases/2025/10-27-2025-203948689" ]
  }.freeze
  # Units a person places, with why. TMI-2 is not part of Crane: Crane is
  # TMI-1 renamed for its restart, and TMI-2 is the 1979 unit, being
  # decommissioned by others.
  PLACE_BY_HAND = {
    "05000320" => "Three Mile Island Unit 2 is not part of the Crane Clean Energy Center, which is Unit 1 renamed " \
      "for its restart. Approve it as its own record, never under Crane."
  }.freeze
  # "San Onofre – Units 2 & 3": the site, then the unit numbers.
  UNIT_PATTERN = /\A(.+?)\s+[–-]\s+Units?\s+(\d+)(?:\s*&\s*(\d+))?\z/
  # A date stamp at the foot of every page, which changes without the facts.
  PAGE_STAMP = /Page Last Reviewed\/Updated [A-Za-z]+, [A-Za-z]+ \d{1,2}, \d{4}/

  # The stored list has no table to extract from.
  class TableMissing < StandardError; end

  def initialize(fetcher: DataQuality::Fetcher.new, licensees: Licensees.new)
    @fetcher = fetcher
    @licensees = licensees
  end

  def crawl(_run)
    list = source(LIST_URL, title: "NRC: power reactor sites undergoing decommissioning")
    stats = { "list" => DataQuality::Snapshot.take(list, fetcher: @fetcher).to_s }
    return stats.merge("stopped" => "list page blocked") if stats["list"] == "blocked"
    return stats unless list.crawl_ok? && list.content_text.present?

    rows = List.rows(list.content_text)
    if rows.empty?
      list.update!(crawl_status: "needs_human", status_reason: TABLE_MISSING)
      return stats.merge("units" => 0)
    end

    stats.merge!("units" => rows.size, "site_pages" => Hash.new(0))
    urls = rows.filter_map(&:page_url).uniq
    withdrawn = withdraw_unlisted_pages(urls)
    stats["withdrawn"] = withdrawn if withdrawn.positive?
    urls.each do |url|
      page = source(url, title: "NRC: #{rows.find { |row| row.page_url == url }.name}")
      result = DataQuality::Snapshot.take(page, fetcher: @fetcher).to_s
      stats["site_pages"][result] += 1
      # A block recorded earlier today (still blocked, or escalated to
      # needs_human) stops a same-day rerun too, before any later page.
      return stats.merge("stopped" => "site page blocked") if result == "blocked" || page.blocked_streak.positive?

      reread_if_units_changed(page)
    end
    stats
  end

  def extract(source, run)
    source.url == LIST_URL ? list_candidates(source) : site_candidates(source, run)
  end

  # The list's table rows, or a site page's text without its date stamp
  # (#240): neither changes when only the stamp does. A site page's also
  # covers the units the list maps to it, since its claims name them.
  def rows_sha256(source)
    return (Digest::SHA256.hexdigest(List.lines(source.content_text).join("\n")) if source.content_text.present?) if source.url == LIST_URL

    text = page_text(source.content_text).gsub(PAGE_STAMP, "")
    units = units_for(source).map { |row| [ row.nrc_docket, unit_name(row) ].join(" ") }.sort
    Digest::SHA256.hexdigest([ text, *units ].join("\n")) if text.present?
  end

  # A unit gone from the list has usually finished decommissioning (its
  # license ended); one that restarted is on NRC's operating list instead.
  def dropped(kind)
    return unless kind == "facility"

    [ { "status" => "shut_down" }, "Approve to mark it shut down: NRC no longer lists it as decommissioning. " \
      "Reject if it restarted (check NRC's operating list)." ]
  end

  # List quotes are whole table rows, as List.lines renders them; a site
  # page's are sentences in its text (the default check).
  def quote_in_source?(source, quote)
    return super unless source.url == LIST_URL

    List.lines(source.content_text).include?(quote)
  end

  def verification_context(source, quote)
    return super unless source.url == LIST_URL

    [ List.lines(source.content_text).first, quote ].compact.join("\n")
  end

  def source_facts(source)
    return unless source.url == LIST_URL

    "This is the NRC's list of power reactor sites undergoing decommissioning in the United States. Every row " \
      "is a nuclear power reactor (plant type: power reactor) in the US (country code US) whose status is " \
      "decommissioning. Location is the city and state where the reactor is."
  end

  # A unit whose owner plans a restart: NRC's status is proposed, and a
  # person decides with the owner's announcement in front of them.
  # TMI-2 too, so a person confirms it isn't put under Crane.
  def hold_for_review(candidate)
    return unless candidate.kind == "facility"

    docket = candidate.payload["nrc_docket"]
    return PLACE_BY_HAND[docket] if PLACE_BY_HAND.key?(docket)
    return unless (plan = RESTART_PLANS[docket])

    note, url = plan
    "NRC lists this unit as decommissioning, so that's the status proposed, and approving it shows its site as " \
      "Decommissioning. #{note} (#{url}); a restart plan is a note, never a status."
  end

  # A site page's main text as one line of text, pieces joined by spaces as
  # the shared quote check reads a page, without NRC's menus and footer.
  def page_text(html)
    doc = Nokogiri::HTML(html.to_s)
    main = doc.at_css("main") || doc.at_css("body") or return ""
    main.css("script, style, template, noscript, nav, header, footer").remove
    main.xpath(".//text()").map(&:text).join(" ").squish
  end

  private
    def source(url, title:)
      Source.find_or_create_by!(url:) do |new_source|
        new_source.source_kind = source_kind
        new_source.title = title
      end
    end

    # A site page the list no longer links to (its last unit moved to another
    # page, or left the list) no longer speaks for any unit: its claims
    # nobody has decided are withdrawn, and one already in a person's review
    # says so. Returns how many were withdrawn.
    UNLISTED = "NRC's decommissioning list no longer links this page"

    def withdraw_unlisted_pages(urls)
      pages = Source.where(source_kind:).where.not(url: [ LIST_URL, *urls ]).select(:id)
      waiting = Candidate.where(source_id: pages)
      waiting.where(status: "needs_review").where("notes IS NULL OR notes NOT LIKE ?", "%#{UNLISTED}%")
        .update_all([ "notes = COALESCE(notes || '. ', '') || ?, updated_at = ?", UNLISTED, Time.current ])
      waiting.where(status: %w[new matched]).update_all(status: "rejected", notes: UNLISTED, updated_at: Time.current)
    end

    # A site page whose units changed on the list (a docket added under it)
    # while its own text didn't is read again: extract skips a page whose
    # content it has already read, so its stored read is cleared.
    def reread_if_units_changed(page)
      return unless page.crawl_ok? && page.extracted_rows_sha256.present?
      return if rows_sha256(page) == page.extracted_rows_sha256

      page.update!(extracted_sha256: nil)
    end

    def list_candidates(source)
      rows = List.rows(source.content_text)
      raise TableMissing, "#{TABLE_MISSING} (#{source.url})" if rows.empty?

      site_candidates_for(rows, source) + rows.map do |row|
        name = unit_name(row)
        { kind: "facility", quote: row.line, payload: {
          "name" => name, "nrc_docket" => row.nrc_docket, "facility_type" => "power_reactor",
          "status" => "decommissioning", "country_code" => "US", "city" => row.city, "state" => row.state,
          "aliases" => ([ row.name ] if name != row.name && single_unit?(row.name))
        }.compact }
      end
    end

    # A site for each plant the list names with several units ("Indian Point
    # – Unit 1" to "Unit 3"), so they count as one plant, not three. Proposed
    # first, so match puts the units under it. A unit of a site the directory
    # already has (Dresden 1) is the list's only row for it, so gets none.
    # A site this list already supports stays while any of its units is
    # listed: down to one unit, it's still decommissioning, and leaving it
    # out would have match suggest the whole site as shut down.
    def site_candidates_for(rows, source)
      supported = source.candidates.where(kind: "facility", status: %w[merged confirmed])
        .where("payload ->> 'nrc_docket' IS NULL").pluck(Arel.sql("payload ->> 'name'")).to_set
      rows.reject { |row| UNIT_NAMES.key?(row.nrc_docket) || PLACE_BY_HAND.key?(row.nrc_docket) }
        .group_by { |row| site_name(row) }.filter_map do |name, units|
          next if name.nil? || (units.size < 2 && !supported.include?(name))

          places = units.map { |row| [ row.city, row.state ] }.uniq
          city, state = places.one? ? places.first : []
          { kind: "facility", quote: units.first.line, payload: {
            "name" => name, "facility_type" => "power_reactor", "status" => "decommissioning", "country_code" => "US",
            "city" => city, "state" => state }.compact }
        end
    end

    def site_name(row) = row.name[UNIT_PATTERN, 1]

    # "Crystal River – Unit 3" => "Crystal River 3", as NRC's operating list
    # names units. "San Onofre – Units 2 & 3" is two rows; each takes its
    # number from its acronym (SONGS2). Anything else keeps NRC's name.
    def unit_name(row)
      return UNIT_NAMES[row.nrc_docket] if UNIT_NAMES.key?(row.nrc_docket)

      match = row.name.match(UNIT_PATTERN)
      return row.name unless match

      site, *numbers = match.captures.compact
      number = numbers.one? ? numbers.first : numbers.find { |n| row.acronym.end_with?(n) }
      number ? "#{site} #{number}" : row.name
    end

    # An NRC name for two units ("Units 2 & 3") can't be an alias of either.
    def single_unit?(name) = !name.match?(/\bUnits\b/)

    # The units the list says this page is about, from the list as stored.
    def units_for(page)
      list = Source.find_by(url: LIST_URL)
      List.rows(list&.content_text).select { |row| row.page_url == page.url }
    end

    def site_candidates(source, run)
      units = units_for(source)
      return [] if units.empty?

      text = page_text(source.content_text)
      return [] if text.blank?

      facilities = units.map { |row| { "name" => unit_name(row), "nrc_docket" => row.nrc_docket } }
      @licensees.call(text, run:).uniq { |answer| [ answer["name"], answer["link"] ] }.flat_map do |answer|
        licensee_candidates(answer, text, facilities)
      end
    end

    def licensee_candidates(answer, text, facilities)
      name, link, quote = answer.values_at("name", "link", "quote").map { |value| value.to_s.squish }
      return [] if name.blank?

      problem = quote_problem(name, quote, text)
      flags = problem ? { status: "needs_review", notes: "The extractor model's quote for #{name} #{problem}" } : {}
      organization = { "name" => name }
      candidates = [ { kind: "organization", payload: organization, quote: }.merge(flags) ]
      candidates += facilities.map do |facility|
        { kind: "facility_relationship", quote:, payload: {
          "organization" => organization, "facility" => facility, "relationship_type" => link } }.merge(flags)
      end
      return candidates unless answer["decommissions"]

      role_quote = answer["decommissioning_quote"].to_s.squish
      role_problem = quote_problem(name, role_quote, text)
      candidates << { kind: "organization_role", quote: role_quote, payload: { "organization" => organization, "role" => ROLE } }
        .merge(role_problem ? { status: "needs_review", notes: "The extractor model's decommissioning quote for #{name} #{role_problem}" } : {})
    end

    # Why a quote can't stand for the claim, or nil: it must be on the page
    # and name the company.
    def quote_problem(name, quote, text)
      return "is empty" if quote.blank?
      return "isn't on the page: #{quote.truncate(120).inspect}" unless text.include?(quote)

      "doesn't name the company: #{quote.truncate(120).inspect}" unless quote.downcase.include?(name.downcase)
    end
end
