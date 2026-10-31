# Instant search's index (#696): every published company and plant site,
# compact, for the browser to filter as people type. Only what the public
# pages show. Keys are short to keep it small:
#
#   { "v" => version,
#     "companies" => [ { "s" => slug, "n" => name, "sn" => short name, "a" => [ other names ],
#                        "d" => short description, "c" => category key, "m" => "Reactor designer · Seattle, WA" } ],
#     "plants" => [ { "s" => slug, "n" => name, "a" => [ other names ], "t" => "Power plant",
#                     "i" => icon name, "m" => "Power plant · Glen Rose, TX" } ] }
#
# "m" is the line the instant results show under a name today; "i" is the
# site's icon (set :nd), so the results look as they do now.
class SearchIndex
  # Changes whenever anything the index shows may have changed: a row
  # updated, added or deleted (the count) in any table it reads.
  def self.version
    stamps = [ Organization, Facility, OrganizationAlias, FacilityAlias, OrganizationRole, Relationship, FacilityRelationship ]
      .map { |model| model.pick(Arel.sql("MAX(updated_at)"), Arel.sql("COUNT(*)")).then { |at, count| "#{at&.utc&.iso8601(6)}/#{count}" } }
    Digest::SHA256.hexdigest(stamps.join("|")).first(16)
  end

  def initialize(helpers: ApplicationController.helpers) = @h = helpers

  def as_json(*) = { "v" => self.class.version, "companies" => companies, "plants" => plants }

  private

  attr_reader :h

  def companies
    list = DirectoryListing.new.companies.to_a
    ids = list.map(&:id)
    aliases = other_names(OrganizationAlias.where(organization_id: ids).pluck(:organization_id, :alias), list)
    roles = OrganizationRole.published.where(organization_id: ids).includes(:role).group_by(&:organization_id)
    categories = Bucket.firsts(list)
    list.map do |company|
      role = roles[company.id]&.map(&:role)&.find { |r| r.parent_id.nil? } || roles[company.id]&.first&.role
      compact("s" => company.slug, "n" => company.name, "sn" => company.short_name, "a" => aliases[company.id],
        "d" => company.short_description, "c" => categories[company.id]&.key,
        "m" => [ (h.role_label(role) if role), h.place(company.hq_city, company.hq_state) ].compact.join(" · ").presence)
    end
  end

  def plants
    list = DirectoryListing.new(category: "plants").plants.to_a
    aliases = other_names(FacilityAlias.where(facility_id: list.map(&:id)).pluck(:facility_id, :alias), list)
    list.map do |plant|
      shown = plant.verified?
      sourced = shown && plant.try(:site_sourced)
      compact("s" => plant.slug, "n" => plant.name, "a" => aliases[plant.id],
        "t" => (h.facility_type_label(plant.facility_type) if shown),
        "i" => h.site_icon_name((plant.facility_type if sourced), reactor_types: [ (plant.reactor_type if sourced), *plant.try(:units_reactor_types) ],
          status: (plant.status if sourced)),
        "m" => ([ h.facility_type_label(plant.facility_type), h.place(plant.city, plant.state) ].compact.join(" · ").presence if shown))
    end
  end

  # Other names only: not the record's own name again, each once.
  def other_names(pairs, records)
    names = records.to_h { |record| [ record.id, record.name.to_s.downcase ] }
    pairs.group_by(&:first).transform_values do |rows|
      rows.map(&:last).compact_blank.uniq(&:downcase).reject { |name| name.downcase == names[rows.first.first] }.presence
    end
  end

  def compact(hash) = hash.compact
end
