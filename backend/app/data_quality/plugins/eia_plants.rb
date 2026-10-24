# The Plant file of EIA's annual Form EIA-860 release (#319): each nuclear
# plant's city, which the monthly 860M file (EiaGenerators) doesn't give.
# - Each plant row proposes its site's city, quoting the row. It never
#   creates or renames a site: a site is found by EIA plant ID, or, for a
#   power plant with no EIA plant ID yet (Columbia, Duane Arnold), by its
#   name and state, which also proposes the plant ID and is held for a person.
# - Only a blank city is filled. A city a person set is never overwritten;
#   a different one comes back as a difference to review (FactWriter).
# - A row with no city proposes nothing.
#
# Crawl reads the EIA-860 page to find the newest yearly zip, fetches it (at
# most once a day, with ETag and Last-Modified; it changes about once a
# year), and stores just the rows of nuclear plants as CSV: every plant the
# same file lists with a nuclear generator, operable or proposed. What's
# stored depends on the file alone, never on the directory, so a "not
# modified" answer can't keep a stale selection. One source per yearly file.
class DataQuality::Plugins::EiaPlants < DataQuality::Plugin
  INDEX_URL = "https://www.eia.gov/electricity/data/eia860/"
  # The EIA-860 page is snapshotted as its own source (never extracted), so
  # it follows the once-a-day fetch rule like any other source.
  INDEX_SOURCE_KIND = "eia_860_index"
  # "xls/eia8602025.zip" or "archive/xls/eia8602024.zip"; an early release
  # ("eia8602026ER.zip") isn't read: its plant data is still revised.
  FILE_LINK = %r{(?:\A|/)xls/eia860(\d{4})\.zip\z}i
  # The 2025 zip is about 24 MB, past the Fetcher's usual 20 MB.
  MAX_BYTES = 60.megabytes
  # Added to an older file's claim still waiting for a person.
  NEWER_FILE = "A newer EIA-860 file exists"

  # The newest final yearly zip linked from the EIA-860 page, as an https URL
  # on EIA's own site under the EIA-860 pages. A link anywhere else is
  # ignored. Shared with EiaOwners, which reads the same zip.
  def self.latest_file_url(html)
    links = Nokogiri::HTML(html).css("a[href]").filter_map { |a| eia_file_url(a["href"].strip) }
    links.max_by { |url| url.path[FILE_LINK, 1].to_i }&.to_s
  end

  def self.eia_file_url(href)
    url = URI.join(INDEX_URL, href)
    index = URI.parse(INDEX_URL)
    url if url.scheme == "https" && url.host == index.host && url.port == index.port &&
      url.path.start_with?(index.path) && url.path.match?(FILE_LINK)
  rescue URI::Error
    nil
  end
  private_class_method :eia_file_url

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @directory = directory
  end

  def crawl(run)
    index = Source.find_or_create_by!(url: INDEX_URL) do |new_source|
      new_source.source_kind = INDEX_SOURCE_KIND
      new_source.title = "EIA-860 annual electric generator data page"
    end
    # Reported, so a failed fetch that falls back on an earlier copy still
    # shows on Today (a same-day rerun skips the fetch and keeps that outcome).
    index_read = DataQuality::Snapshot.take(index, fetcher: @fetcher).to_s
    raise "EIA-860 page: #{index.status_reason || index.crawl_status}" unless index.crawl_ok? && index.content_text.present?

    url = self.class.latest_file_url(index.content_text) or raise "EIA-860 page: no yearly zip link found; the page may have changed"
    source = Source.find_or_create_by!(url:) do |new_source|
      new_source.source_kind = source_kind
      new_source.title = "EIA-860 annual plant file, #{url[FILE_LINK, 1]}"
    end

    result = DataQuality::Snapshot.take(source, fetcher: @fetcher, binary: true, max_bytes: MAX_BYTES) do |bytes|
      PlantFile.to_csv(PlantFile.plants(bytes))
    end
    { "index" => index_read, "file" => url, "snapshot" => result.to_s, "plants" => [ CSV.parse(source.reload.content_text.to_s).size - 1, 0 ].max,
      "superseded" => (supersede_older_files(source) if source.crawl_ok?) }.compact
  rescue PlantFile::Unreadable => error
    source.update!(crawl_status: "needs_human", status_reason: "Couldn't read the EIA-860 plant file: #{error.message}")
    { "index" => index_read, "file" => url, "snapshot" => "needs_human" }
  end

  def source_facts(source)
    return unless source.source_kind == source_kind

    "This is the Plant sheet of EIA's annual Form EIA-860 file, kept to nuclear power plants in the US. Every row " \
      "is one plant. Columns, in order: #{PlantFile::COLUMNS.values.join(', ')}. City, State and Zip are the " \
      "plant's address."
  end

  # Match finds the site: by EIA plant ID, or a power plant with none by
  # name and state, looked up on every run (Match#match_site_enrichment).
  def extract(source, _run)
    CSV.parse(source.content_text.to_s, headers: true).filter_map do |row|
      next if row["city"].blank?

      identify = { "eia_plant_id" => row["eia_plant_id"], "name" => row["plant_name"], "state" => row["state"] }.compact
      { kind: "facility", quote: row.to_csv.chomp, payload: { "identify" => identify, "city" => row["city"] } }
    end
  end

  # A plant found by name is a person's call: its EIA plant ID is set with
  # the city, or, for a one-record plant with its NRC docket (Columbia),
  # can't be, since only a site carries one.
  def hold_for_review(candidate)
    return unless candidate.kind == "facility" && candidate.payload.dig("identify", "site_id")

    plant = candidate.payload.dig("identify", "eia_plant_id")
    if candidate.payload["eia_plant_id"]
      "Found by name: this plant has no EIA plant ID, and EIA's plant file names plant #{plant} here. " \
        "Approving sets that EIA plant ID and the city."
    else
      "Found by name: EIA's plant file names plant #{plant} here. This plant is one record with its NRC docket, so " \
        "it can't take an EIA plant ID until it's split into a site and its unit. Approving sets only the city."
    end
  end

  # Earlier yearly files (#542): each year is its own source, older first.
  def earlier_editions(source)
    current = source.url.to_s[FILE_LINK, 1].to_i
    return [] if current.zero?

    Source.where(source_kind:).where.not(id: source.id).select { |other| other.url.to_s[FILE_LINK, 1].to_i.between?(1, current - 1) }
      .sort_by { |other| other.url.to_s[FILE_LINK, 1].to_i }.map(&:id)
  end

  private
    # Once a newer yearly file is read, candidates from older ones that
    # nobody has decided yet are withdrawn: an older year's address mustn't
    # be approved over the newer one. A claim already waiting for a person
    # (found by name) stays where it is, with a warning on it, as
    # EiaGenerators does; the newer file's own claim sits next to it.
    def supersede_older_files(source)
      year = source.url[FILE_LINK, 1].to_i
      older = Source.where(source_kind:).where.not(id: source.id).select { |other| other.url[FILE_LINK, 1].to_i < year }
      return 0 if older.empty?

      Candidate.transaction do
        waiting = Candidate.where(source_id: older.map(&:id))
        waiting.where(status: "needs_review").where.not("notes LIKE ?", "%#{NEWER_FILE}%")
          .update_all([ "notes = COALESCE(notes || '. ', '') || ?, updated_at = ?", "#{NEWER_FILE}: #{source.title}", Time.current ])
        waiting.where(status: %w[new matched])
          .update_all(status: "rejected", notes: "Superseded by the newer #{source.title}", updated_at: Time.current)
      end
    end
end
