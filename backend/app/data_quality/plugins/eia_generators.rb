# EIA's monthly generator inventory (Form EIA-860M, #61): capacity and
# coordinates for nuclear units, and (#121) the plants.
# - Each generator enriches its NRC unit (capacity_mw, state, latitude,
#   longitude); it never creates or renames a unit.
# - Each plant also proposes its site (by EIA plant ID and name), so the
#   directory can grow when NRC's list can't be read. Not its operator: EIA's
#   Entity Name is the reporting utility (#227). NRC stays preferred for dockets, reactor
#   types and licensees: a site found by name keeps what it has, agreement adds
#   EIA's row as evidence, and a disagreement with a human-reviewed value goes
#   to review. A site is found by EIA plant ID first, so nothing duplicates.
#
# Crawl reads EIA's 860M page to find the newest monthly file, fetches it,
# and stores just its nuclear rows as CSV (one source per monthly file, so
# evidence points at the exact file). Extract turns each row into a facility
# candidate whose payload carries "identify" (how to find the unit) and the
# values to set. The match stage finds the unit by state, name and unit
# number; see app/data_quality/README.md.
class DataQuality::Plugins::EiaGenerators < DataQuality::Plugin
  INDEX_URL = "https://www.eia.gov/electricity/data/eia860m/"
  # The 860M page is snapshotted as its own source (never extracted), so it
  # follows the once-a-day fetch rule like any other source.
  INDEX_SOURCE_KIND = "eia_860m_index"
  # Date::MONTHNAMES is [nil, "January", ...]; "january|february|...|december".
  MONTH_NAMES_RE = Date::MONTHNAMES.compact.join("|").downcase.freeze
  # Only real month names, so a bogus "xyz_generator2026.xlsx" never matches
  # (its Date::MONTHNAMES.index would be nil and sort as month 0, #118).
  FILE_LINK = %r{(?:\A|/)xls/(#{MONTH_NAMES_RE})_generator(\d{4})\.xlsx\z}i

  def initialize(fetcher: DataQuality::Fetcher.new)
    @fetcher = fetcher
  end

  def crawl(run)
    # First, so it happens even when EIA's page can't be read today.
    withdrawn = withdraw_operator_claims(run)
    index = Source.find_or_create_by!(url: INDEX_URL) do |new_source|
      new_source.source_kind = INDEX_SOURCE_KIND
      new_source.title = "EIA-860M monthly generator inventory page"
    end
    # Reported, so a failed fetch that falls back on yesterday's copy still shows on Today.
    index_read = DataQuality::Snapshot.take(index, fetcher: @fetcher).to_s
    unless index.crawl_ok? && index.content_text.present?
      raise "EIA 860M page: #{index.status_reason || index.crawl_status}"
    end

    url = latest_file_url(index.content_text) or raise "EIA 860M page: no monthly generator file link found; the page may have changed"
    source = Source.find_or_create_by!(url: url) do |new_source|
      new_source.source_kind = source_kind
      new_source.title = "EIA-860M generator inventory, #{url[FILE_LINK, 1].capitalize} #{url[FILE_LINK, 2]}"
    end

    # The shared Fetcher keeps every fetch, redirects included, on public https
    # addresses of the starting host (#114).
    result = DataQuality::Snapshot.take(source, fetcher: @fetcher, binary: true) do |bytes|
      Workbook.to_csv(Workbook.nuclear_generators(bytes))
    end
    { "index" => index_read, "file" => url, "snapshot" => result.to_s, "generators" => [ CSV.parse(source.reload.content_text.to_s).size - 1, 0 ].max,
      "superseded" => (supersede_older_files(source, run) if source.crawl_ok?),
      "operator_claims_withdrawn" => (withdrawn if withdrawn.positive?) }.compact
  rescue Workbook::Unreadable => error
    source.update!(crawl_status: "needs_human", status_reason: "Couldn't read the EIA workbook: #{error.message}")
    { "index" => index_read, "file" => url, "snapshot" => "needs_human", "operator_claims_withdrawn" => (withdrawn if withdrawn.to_i.positive?) }.compact
  end

  # EIA's status code for a plant in service; anything else (standby, out of
  # service…) is left blank rather than guessed.
  STATUSES = { "OP" => "operating" }.freeze

  # The stored CSV keeps only nuclear rows of the Operating sheet and drops
  # the Technology column, so the verifier is told what every row is.
  def source_facts(source)
    return unless source.source_kind == source_kind

    "This is the Operating sheet of EIA's monthly generator inventory (Form EIA-860M), kept to " \
      "generators whose technology is Nuclear. Every row is a nuclear power reactor (plant type: " \
      "power reactor) at a plant in the US (country code US). Columns, in order: " \
      "#{Workbook::COLUMNS.values.join(', ')}. Status is EIA's status for the unit, e.g. " \
      "\"(OP) Operating\". Entity Name is the entity that reports the generator to EIA."
  end

  def extract(source, _run)
    rows = CSV.parse(source.content_text.to_s, headers: true).reject { |row| row["state"].blank? || row["plant_name"].blank? }
    rows.map { |row| enrichment(row) } + rows.group_by { |row| row["eia_plant_id"] }.flat_map { |_, plant| plant_candidates(plant) }
  end

  private
    # A generator's capacity and place, for its NRC unit (#61).
    def enrichment(row)
      {
        kind: "facility",
        payload: {
          "identify" => row.to_h.slice("plant_name", "state", "generator_id", "eia_plant_id")
            .transform_keys("plant_name" => "name", "generator_id" => "unit"),
          "capacity_mw" => number(row["net_summer_capacity_mw"], 1),
          # EIA's plant state is the unit's state (Tosin, 2026-10-10): NRC's list
          # only names a nearby city, which is in another state for border plants.
          "state" => row["state"],
          "latitude" => number(row["latitude"], 6),
          "longitude" => number(row["longitude"], 6)
        }.compact,
        quote: row.to_csv.chomp
      }
    end

    # The plant's site (#121), quoting its first generator row. No operator:
    # EIA's Entity Name is the utility that reports the generator, not the
    # plant's operator (Hatch reads Georgia Power; the operator is Southern
    # Nuclear), so NRC's list stays the only source of operators (#227).
    def plant_candidates(rows)
      row = rows.first
      quote = row.to_csv.chomp
      site = { "name" => row["plant_name"], "eia_plant_id" => row["eia_plant_id"] }
      [ {
        kind: "facility",
        payload: site.merge(
          "facility_type" => "power_reactor",
          "status" => STATUSES[row["status"].to_s[/\A\((\w+)\)/, 1]],
          "state" => row["state"],
          "latitude" => number(row["latitude"], 6),
          "longitude" => number(row["longitude"], 6)
        ).compact,
        quote:
      } ]
    end

    # Operator claims EIA proposed before #227 that nobody has decided yet are
    # withdrawn, with the reason, and so is any company or link they
    # proposed that nothing else uses. Published ones are left to a person
    # (bin/rails directory:retire_eia_operators). Runs on every crawl, so
    # claims reopened later are withdrawn too. Returns how many.
    WITHDRAWN = "EIA's Entity Name is the utility that reports the generator, not the plant's operator; " \
      "operators come from NRC's list (#227)"

    def withdraw_operator_claims(run)
      # Locked, as a review decision locks them: one a person approves or
      # rejects at the same moment is either decided first (and skipped
      # here, as Postgres rechecks the status) or waits and sees it withdrawn.
      Candidate.transaction do
        open = Candidate.where(source_id: Source.where(source_kind:).select(:id), kind: %w[organization facility_relationship],
          status: %w[new matched needs_review]).order(:id).lock.to_a
        next 0 if open.empty?

        Candidate.where(id: open.map(&:id)).update_all(status: "rejected", notes: WITHDRAWN, updated_at: Time.current)
        retire_orphans(open.select(&:subject_id), nil, run)
        open.size
      end
    end

    # Once a newer monthly file is read, candidates from older files that
    # haven't been published yet are withdrawn: an older month approved after
    # a newer one would overwrite current capacity and coordinates.
    # Only files from an earlier month count as older: if the index ever
    # points back at an earlier file, a later month's candidates are kept.
    # Candidates already in a human's review stay there, with a note that a
    # newer file exists (some were published and only need a site checked).
    def supersede_older_files(source, run)
      current = file_month(source.url)
      older = Source.where(source_kind:).where.not(id: source.id).select { |other| (file_month(other.url) <=> current) == -1 }
      return 0 if older.empty?

      # One transaction: a run stopped part-way leaves the candidates
      # unwithdrawn, so the next run retries their retirements too.
      Candidate.transaction do
        waiting = Candidate.where(source_id: older.map(&:id))
        waiting.where(status: "needs_review").where.not("notes LIKE ?", "%A newer EIA file exists%")
          .update_all([ "notes = COALESCE(notes || '. ', '') || ?, updated_at = ?", "A newer EIA file exists: #{source.title}", Time.current ])
        withdrawn = waiting.where(status: %w[new matched]).to_a
        Candidate.where(id: withdrawn.map(&:id))
          .update_all(status: "rejected", notes: "Superseded by the newer #{source.title}", updated_at: Time.current)
        retire_orphans(withdrawn.select(&:subject_id), source, run)
        withdrawn.size
      end
    end

    # A proposed record a withdrawn candidate pointed at is retired
    # (rejected, as the verify stage does for a rejected proposal) only when
    # the newer file no longer has it and no live candidate points at it.
    # "Has it" is by plant for a site. A company or operates link is never
    # "had" any more: EIA no longer proposes operators (#227). A record still
    # in the newer file keeps its proposal, which the newer file's candidates
    # then match. The proposing candidate may be from any earlier month: after
    # one supersession, a later month's candidate attaches without proposing.
    # source: nil when withdrawing operator claims (no file to compare).
    def retire_orphans(candidates, source, run)
      plants = CSV.parse(source&.content_text.to_s, headers: true).map { |row| row["eia_plant_id"] }.to_set
      directory = DataQuality::DirectoryClient.new
      candidates.uniq { |c| [ c.subject_type, c.subject_id ] }.each do |candidate|
        next if kept?(candidate, plants)

        # Under the record's lock, as Review#retire_proposal does: another
        # source's match attaching to it at the same moment either lands
        # first (and keeps it) or waits until it's retired. Already closed:
        # nothing to retire.
        result = nil
        directory.unless_closed(candidate) do
          attached = Candidate.where(subject_type: candidate.subject_type, subject_id: candidate.subject_id)
          next unless attached.where(proposed_subject: true).exists?
          next if attached.where(status: %w[new matched merged needs_review]).exists?

          result = directory.retire(candidate, crawl_run: run)
        end
        # Any failure undoes the withdrawal too, so the next run tries again.
        next if result.nil? || result.success?

        raise "Couldn't retire #{candidate.subject_type} #{candidate.subject_id}: #{result.errors.join('; ')}"
      end
    end

    # A site the newer file still lists keeps its proposal. Companies and
    # operates links from EIA never do (#227); other kinds aren't EIA's.
    def kept?(candidate, plants)
      case candidate.kind
      when "facility" then plants.include?(candidate.payload["eia_plant_id"])
      when "organization", "facility_relationship" then false
      else true
      end
    end

    # [year, month] of a monthly file URL, or nil when it isn't one.
    def file_month(url)
      month, year = URI.parse(url).path.match(FILE_LINK)&.captures
      [ year.to_i, Date::MONTHNAMES.index(month.capitalize).to_i ] if month
    rescue URI::Error
      nil
    end

    # The newest "<month>_generator<year>.xlsx" linked from the page, as an
    # https URL on EIA's own site under the 860M pages. A link anywhere else
    # is ignored, so the page can never point the crawler at another host.
    def latest_file_url(html)
      links = Nokogiri::HTML(html).css("a[href]").filter_map { |a| eia_file_url(a["href"].strip) }
      newest = links.max_by do |url|
        month, year = url.path.match(FILE_LINK).captures
        [ year.to_i, Date::MONTHNAMES.index(month.capitalize).to_i ]
      end
      newest&.to_s
    end

    def eia_file_url(href)
      url = URI.join(INDEX_URL, href)
      index = URI.parse(INDEX_URL)
      url if url.scheme == "https" && url.host == index.host && url.port == index.port &&
        url.path.start_with?(index.path) && url.path.match?(FILE_LINK)
    rescue URI::Error
      nil
    end

    # Strict: the workbook reader already refused anything that isn't a number.
    def number(value, digits) = value.present? ? BigDecimal(value).round(digits).to_s("F") : nil
end
