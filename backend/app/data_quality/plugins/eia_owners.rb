# Who owns each nuclear plant, from EIA's annual Form EIA-860 (#382): the
# generator file's ownership code and Schedule 4, "Ownership of Generators",
# read from the same yearly zip as EiaPlants (OwnerFile says how).
# - One "owns" claim per owner per plant, on the site found by EIA plant ID,
#   with the owner's share as ownership_pct, when every owner has the same
#   share of every unit. Where a share differs between units (Catawba), the
#   claims go on each unit instead, held for a person.
# - Each owner is a company claim too, found by EIA utility ID first, then
#   by name. A new owner is proposed under EIA's name, never published on its
#   own; Data Quality sets its brand name in review.
# - Held for a person, whatever the verifier says: a plant whose shares
#   don't add up to 100% ± 1, per-unit claims, and a new owner on a plant
#   that already has published owners. A change to a share a person set
#   goes to review as a difference, and an owner that leaves the file as a
#   dropped claim, as for every source.
#
# One source per yearly file, the zip's own address with "#owners" on the
# end, so it has its own snapshot, validators and once-a-day fetch.
class DataQuality::Plugins::EiaOwners < DataQuality::Plugin
  Plants = DataQuality::Plugins::EiaPlants
  ANCHOR = "#owners"
  # The shares at a plant may add up to this much off 100% and still be
  # published without a person (rounding in EIA's file).
  TOLERANCE = BigDecimal("1")

  def initialize(fetcher: DataQuality::Fetcher.new, directory: DataQuality::DirectoryClient.new)
    @fetcher = fetcher
    @directory = directory
  end

  def crawl(run)
    index = Source.find_or_create_by!(url: Plants::INDEX_URL) do |new_source|
      new_source.source_kind = Plants::INDEX_SOURCE_KIND
      new_source.title = "EIA-860 annual electric generator data page"
    end
    DataQuality::Snapshot.take(index, fetcher: @fetcher)
    raise "EIA-860 page: #{index.status_reason || index.crawl_status}" unless index.crawl_ok? && index.content_text.present?

    file = Plants.latest_file_url(index.content_text) or raise "EIA-860 page: no yearly zip link found; the page may have changed"
    source = Source.find_or_create_by!(url: "#{file}#{ANCHOR}") do |new_source|
      new_source.source_kind = source_kind
      new_source.title = "EIA-860 annual generator ownership, #{year(file)}"
    end
    result = DataQuality::Snapshot.take(source, fetcher: @fetcher, binary: true, max_bytes: Plants::MAX_BYTES) do |bytes|
      OwnerFile.to_csv(OwnerFile.rows(bytes))
    end
    { "file" => file, "snapshot" => result.to_s, "rows" => [ CSV.parse(source.reload.content_text.to_s).size - 1, 0 ].max,
      "superseded" => (supersede_older_files(source) if source.crawl_ok?) }.compact
  rescue OwnerFile::Unreadable => error
    source.update!(crawl_status: "needs_human", status_reason: "Couldn't read EIA-860's ownership: #{error.message}")
    { "file" => file, "snapshot" => "needs_human" }
  end

  def source_facts(source)
    return unless source.source_kind == source_kind

    "This is who owns each nuclear generator in EIA's annual Form EIA-860 file, kept to nuclear power plants in the " \
      "US. Every row is one generator and one of its owners. Columns, in order: #{OwnerFile::COLUMNS.values.join(', ')}. " \
      "Ownership is EIA's code: S means the owner named is the utility that reports the generator, and owns it alone " \
      "(100%), so Percent Owned is blank; J (jointly owned) and W (wholly owned by another company) rows come from " \
      "EIA-860 Schedule 4, where Percent Owned is the owner's share as a fraction (0.3 is 30%). When an owner has the " \
      "same share of every generator at a plant, that is its share of the plant."
  end

  def extract(source, _run)
    plants = shares(source)
    owners = plants.values.flat_map { |plant| plant[:rows] }.group_by { |row| row["owner_eia_utility_id"] }
    owners.map { |_, rows| owner_candidate(rows.first) } + plants.values.flat_map { |plant| link_candidates(plant) }
  end

  # A person decides a claim whose shares don't add up, one on a unit, and a
  # new owner on a plant that already has published owners.
  def hold_for_review(candidate)
    return unless candidate.kind == "facility_relationship"

    facility = candidate.payload["facility"].to_h
    plant = shares(candidate.source).values.find do |each|
      each[:eia_plant_id] == facility["eia_plant_id"] || each[:units].key?(facility["name"])
    end
    return unless plant

    unless facility["eia_plant_id"]
      return "EIA gives this plant's owners different shares for each unit, so this claim is on the unit " \
        "(#{facility['name']}). Check that the unit matched is the one EIA means."
    end
    total = plant[:total]
    if (total - 100).abs > TOLERANCE
      return "The owners' shares at #{plant[:name]} add up to #{format_pct(total)}% in EIA's file, not 100%: " \
        "#{plant[:owners].map { |owner| "#{owner[:name]} #{format_pct(owner[:pct])}%" }.join(', ')}."
    end
    new_owner_reason(candidate)
  end

  private
    def year(file) = file[Plants::FILE_LINK, 1]

    # Each plant in the source's rows: { plant id => { eia_plant_id:, name:,
    # rows:, owners: [{ id:, name:, pct:, rows: }], total:, per_unit:,
    # units: { "Catawba 1" => [{ id:, name:, pct:, row: }] } } }. Cached per snapshot.
    def shares(source)
      @shares ||= {}
      @shares[[ source.id, source.content_sha256 ]] ||= begin
        rows = CSV.parse(source.content_text.to_s, headers: true).map(&:to_h)
        rows.group_by { |row| row["eia_plant_id"] }.transform_values { |plant_rows| plant(plant_rows) }
      end
    end

    # An owner's share of the plant is its share of each unit when that's the
    # same for every unit; when it isn't (Catawba), the claims are per unit.
    def plant(rows)
      first = rows.first
      units_of_plant = rows.map { |row| row["generator_id"] }.uniq
      by_owner = rows.group_by { |row| row["owner_eia_utility_id"] }
      fraction = ->(row) { row["ownership"] == OwnerFile::SOLE ? BigDecimal("1") : BigDecimal(row["percent_owned"].presence || "0") }
      share_of = by_owner.transform_values { |owner_rows| owner_rows.to_h { |row| [ row["generator_id"], fraction.(row) ] } }
      per_unit = share_of.values.any? { |by_unit| units_of_plant.map { |unit| by_unit.fetch(unit, 0) }.uniq.size > 1 }
      owners = by_owner.map do |id, owner_rows|
        { id:, name: owner_rows.first["owner_name"], rows: owner_rows, pct: (share_of[id].values.first * 100).round(2) }
      end
      units = rows.group_by { |row| "#{row['plant_name']} #{row['generator_id']}" }.transform_values do |unit_rows|
        unit_rows.map { |row| { id: row["owner_eia_utility_id"], name: row["owner_name"], pct: (fraction.(row) * 100).round(2), row: } }
      end
      { eia_plant_id: first["eia_plant_id"], name: first["plant_name"], rows:, owners:, total: owners.sum { |owner| owner[:pct] },
        per_unit:, units: }
    end

    def owner_candidate(row)
      name = row["owner_name"]
      display = name == name.upcase ? name.titleize : name
      { kind: "organization", quote: line(row),
        payload: { "name" => display, "eia_utility_id" => row["owner_eia_utility_id"], "aliases" => ([ name ] if display != name) }.compact }
    end

    def link_candidates(plant)
      unless plant[:per_unit]
        facility = { "eia_plant_id" => plant[:eia_plant_id], "name" => plant[:name] }
        return plant[:owners].map { |owner| link(owner, facility, owner[:pct], owner[:rows].map { |row| line(row) }.join("\n")) }
      end

      plant[:units].flat_map do |unit_name, owners|
        owners.select { |owner| owner[:pct].positive? }.map { |owner| link(owner, { "name" => unit_name }, owner[:pct], line(owner[:row])) }
      end
    end

    def link(owner, facility, pct, quote)
      { kind: "facility_relationship", quote:,
        payload: { "organization" => { "name" => owner[:name], "eia_utility_id" => owner[:id] }, "facility" => facility,
          "relationship_type" => "owns", "ownership_pct" => pct.to_s("F").sub(/\.0\z/, "") } }
    end

    # A stored row as it reads in the source: the quote.
    def line(row) = row.values.to_csv.chomp

    def format_pct(value) = value.round(2).to_s("F").sub(/\.0\z/, "")

    # An owner not already among a plant's published owners, on a plant that
    # has some, is a person's call (a sale, or a new co-owner).
    def new_owner_reason(candidate)
      link = candidate.subject_id && @directory.fact(type: "FacilityRelationship", id: candidate.subject_id) or return
      return if @directory.published?(type: "FacilityRelationship", id: candidate.subject_id)

      owners = @directory.published_owner_ids(facility_id: link.values["facility_id"]) - [ link.values["organization_id"] ]
      return if owners.empty?

      "A new owner for a plant that already has published owners: approving adds #{candidate.payload.dig('organization', 'name')} " \
        "beside them. Check whether it bought a share, or a name changed."
    end

    # Once a newer yearly file is read, the older file's undecided claims are
    # withdrawn, and those waiting for a person are warned, as EiaPlants does.
    def supersede_older_files(source)
      current = year(source.url.delete_suffix(ANCHOR)).to_i
      older = Source.where(source_kind:).where.not(id: source.id).select { |other| year(other.url.delete_suffix(ANCHOR)).to_i < current }
      return 0 if older.empty?

      Candidate.transaction do
        waiting = Candidate.where(source_id: older.map(&:id))
        waiting.where(status: "needs_review").where.not("notes LIKE ?", "%#{Plants::NEWER_FILE}%")
          .update_all([ "notes = COALESCE(notes || '. ', '') || ?, updated_at = ?", "#{Plants::NEWER_FILE}: #{source.title}", Time.current ])
        waiting.where(status: %w[new matched])
          .update_all(status: "rejected", notes: "Superseded by the newer #{source.title}", updated_at: Time.current)
      end
    end
end
