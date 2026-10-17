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
# year), and stores just the rows of nuclear plants as CSV: plants in EIA's
# latest monthly file, plants the directory has by EIA plant ID, and power
# plants it has without one, by name and state. One source per yearly file.
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
  MONTHLY_KIND = "eia_generators"

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @directory = directory
  end

  def crawl(run)
    index = Source.find_or_create_by!(url: INDEX_URL) do |new_source|
      new_source.source_kind = INDEX_SOURCE_KIND
      new_source.title = "EIA-860 annual electric generator data page"
    end
    DataQuality::Snapshot.take(index, fetcher: @fetcher)
    raise "EIA-860 page: #{index.status_reason || index.crawl_status}" unless index.crawl_ok? && index.content_text.present?

    url = latest_file_url(index.content_text) or raise "EIA-860 page: no yearly zip link found; the page may have changed"
    source = Source.find_or_create_by!(url:) do |new_source|
      new_source.source_kind = source_kind
      new_source.title = "EIA-860 annual plant file, #{url[FILE_LINK, 1]}"
    end

    keep = nuclear_plant(@directory.eia_plant_ids.to_set | monthly_plant_ids, plants_by_name)
    result = DataQuality::Snapshot.take(source, fetcher: @fetcher, binary: true, max_bytes: MAX_BYTES) do |bytes|
      PlantFile.to_csv(PlantFile.plants(bytes, keep:))
    end
    { "file" => url, "snapshot" => result.to_s, "plants" => [ CSV.parse(source.reload.content_text.to_s).size - 1, 0 ].max,
      "superseded" => (supersede_older_files(source) if source.crawl_ok?) }.compact
  rescue PlantFile::Unreadable => error
    source.update!(crawl_status: "needs_human", status_reason: "Couldn't read the EIA-860 plant file: #{error.message}")
    { "file" => url, "snapshot" => "needs_human" }
  end

  def source_facts(source)
    return unless source.source_kind == source_kind

    "This is the Plant sheet of EIA's annual Form EIA-860 file, kept to nuclear power plants in the US. Every row " \
      "is one plant. Columns, in order: #{PlantFile::COLUMNS.values.join(', ')}. City, State and Zip are the " \
      "plant's address."
  end

  def extract(source, _run)
    by_name = plants_by_name
    CSV.parse(source.content_text.to_s, headers: true).filter_map do |row|
      next if row["city"].blank?

      plant = row["eia_plant_id"]
      found = by_name[name_key(row["plant_name"], row["state"])] unless @directory.facility(eia_plant_id: plant)
      identify = { "eia_plant_id" => plant, "name" => row["plant_name"], "site_id" => found&.dig(:id) }.compact
      { kind: "facility", quote: row.to_csv.chomp,
        payload: { "identify" => identify, "city" => row["city"], "eia_plant_id" => (plant if found&.dig(:site)) }.compact }
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

  private
    # Whether a plant row is a nuclear plant the directory can use.
    def nuclear_plant(plant_ids, by_name)
      ->(plant) { plant_ids.include?(plant["eia_plant_id"]) || by_name.key?(name_key(plant["plant_name"], plant["state"])) }
    end

    # The plant IDs in EIA's newest monthly file, all nuclear (EiaGenerators).
    def monthly_plant_ids
      latest = Source.where(source_kind: MONTHLY_KIND, crawl_status: "ok").where.not(content_text: nil).order(:fetched_at, :id).last
      CSV.parse(latest&.content_text.to_s, headers: true).filter_map { |row| row["eia_plant_id"].presence }.to_set
    end

    # { [name, state] => { id:, site: } } for power plants with no EIA plant
    # ID. A name two plants share in one state finds neither.
    def plants_by_name
      keys = @directory.plants_without_eia_plant_id.flat_map do |plant|
        plant[:names].map { |name| [ name_key(name, plant[:state]), plant.slice(:id, :site) ] }
      end
      keys.group_by(&:first).filter_map { |key, found| [ key, found.first.last ] if key && found.map(&:last).uniq.one? }.to_h
    end

    def name_key(name, state)
      [ @directory.normalize_facility_name(name), state.to_s.strip.upcase ] if name.present? && state.present?
    end

    # Once a newer yearly file is read, candidates from older ones that
    # nobody has decided yet are withdrawn: an older year's address mustn't
    # be approved over the newer one.
    def supersede_older_files(source)
      year = source.url[FILE_LINK, 1].to_i
      older = Source.where(source_kind:).where.not(id: source.id).select { |other| other.url[FILE_LINK, 1].to_i < year }
      return 0 if older.empty?

      Candidate.where(source_id: older.map(&:id), status: %w[new matched])
        .update_all(status: "rejected", notes: "Superseded by the newer #{source.title}", updated_at: Time.current)
    end

    # The newest final yearly zip linked from the page, as an https URL on
    # EIA's own site under the EIA-860 pages. A link anywhere else is ignored.
    def latest_file_url(html)
      links = Nokogiri::HTML(html).css("a[href]").filter_map { |a| eia_file_url(a["href"].strip) }
      links.max_by { |url| url.path[FILE_LINK, 1].to_i }&.to_s
    end

    def eia_file_url(href)
      url = URI.join(INDEX_URL, href)
      index = URI.parse(INDEX_URL)
      url if url.scheme == "https" && url.host == index.host && url.port == index.port &&
        url.path.start_with?(index.path) && url.path.match?(FILE_LINK)
    rescue URI::Error
      nil
    end
end
