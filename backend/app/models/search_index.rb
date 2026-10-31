# Instant search's index (#696): every published company and plant site,
# compact, for the browser to filter as people type and draw the same rows
# as today's instant results. Only what the public pages show. Shape agreed
# with Site (31 Oct):
#
#   { "v" => version,
#     "icons" => { key => "<svg ...>" },   # only the icons in use
#     "items" => [ { "k" => "c" or "p", "s" => slug, "n" => name, "sn" => short name, "a" => [ other names ],
#                    "d" => short description, "m" => "Reactor designer · Seattle, WA", "i" => icon key,
#                    "b" => "nd-bucket--fuel", "c" => connection count,
#                    "x" => [ IDs people search by: ticker; NRC dockets and EIA plant ID of a site and its units ] } ],
#     "tags" => [ { "s" => tag key, "n" => "Small modular reactors", "a" => [ "smr", "small modular" ],
#                   "c" => company count, "i" => icon key } ] }   # a topic page: /companies?tag=key
#
# Companies, then plant sites, each Most connected first. Empty keys are left out.
class SearchIndex
  # Changes whenever anything the index shows may have changed: a row
  # updated, added or deleted (the count) in any table it reads.
  def self.version
    stamps = [ Organization, Facility, OrganizationAlias, FacilityAlias, OrganizationRole, OrganizationTechnology, Relationship, FacilityRelationship, Evidence ]
      .map { |model| model.pick(Arel.sql("MAX(updated_at)"), Arel.sql("COUNT(*)")).then { |at, count| "#{at&.utc&.iso8601(6)}/#{count}" } }
    Digest::SHA256.hexdigest(stamps.join("|")).first(16)
  end

  def initialize(helpers: ApplicationController.helpers) = @h = helpers

  def as_json(*)
    @icons = {}
    items = companies + plants
    { "v" => self.class.version, "icons" => @icons, "items" => items, "tags" => topics }
  end

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
      category = categories[company.id]
      # As company_square draws it: the category's icon, else a building.
      key = if category
        icon_key("nd-#{category.plants ? 'site-plant' : "bucket-#{category.key}"}-16") { h.bucket_icon(category) }
      else
        icon_key("buildings-16") { h.icon("buildings") }
      end
      compact("k" => "c", "s" => company.slug, "n" => company.name, "sn" => company.short_name, "a" => aliases[company.id],
        "d" => company.short_description, "i" => key, "b" => (h.bucket_class(category) if category),
        "m" => [ (h.role_label(role) if role), h.place(company.hq_city, company.hq_state) ].compact.join(" · ").presence,
        "c" => company.try(:connections_count).to_i, "x" => [ company.ticker ].compact.presence)
    end
  end

  # Words people type for a topic besides its name (Tosin, 31 Oct: "HALEU", "SMR").
  TOPIC_WORDS = {
    "smr" => [ "smr", "smrs", "small modular" ], "uranium" => [ "mining", "milling", "uranium mining" ],
    "enrichment" => [ "haleu", "leu", "enriched uranium" ], "fuel-fabrication" => [ "fuel", "triso", "fabrication" ],
    "isotopes" => [ "medical isotopes", "radioisotopes" ], "national-labs" => [ "national lab", "doe lab" ],
    "venture-capital" => [ "vc", "investors" ], "data-center-buyers" => [ "data centers", "hyperscalers" ]
  }.freeze

  # The topic pages that list someone (PublicPages#tags), with their words, count and icon.
  def topics
    PublicPages.new.tags.map do |tag|
      icon, bucket = h.tag_square(tag, size: 16)
      compact("s" => tag.key, "n" => tag.name, "a" => TOPIC_WORDS[tag.key], "c" => Organization.where(id: tag.organization_ids).count,
        "i" => (icon_key("tag-#{tag.key}-16") { icon } if icon), "b" => (h.bucket_class(bucket) if bucket))
    end
  end

  def plants
    list = DirectoryListing.new(category: "plants").plants.to_a
    aliases = other_names(FacilityAlias.where(facility_id: list.map(&:id)).pluck(:facility_id, :alias), list)
    units = Facility.published.where(parent_id: list.map(&:id)).pluck(:parent_id, :nrc_docket).group_by(&:first)
    list.map do |plant|
      shown = plant.verified?
      sourced = shown && plant.try(:site_sourced)
      name = h.site_icon_name((plant.facility_type if sourced), reactor_types: [ (plant.reactor_type if sourced), *plant.try(:units_reactor_types) ],
        status: (plant.status if sourced))
      compact("k" => "p", "s" => plant.slug, "n" => plant.name, "a" => aliases[plant.id],
        "i" => icon_key("nd-#{name}-20") { h.icon(name, set: :nd, size: 20) },
        "m" => ([ h.facility_type_label(plant.facility_type), h.place(plant.city, plant.state) ].compact.join(" · ").presence if shown),
        "c" => plant.try(:connections_count).to_i,
        "x" => [ plant.nrc_docket, plant.eia_plant_id, *units[plant.id]&.map(&:last) ].compact_blank.uniq.presence)
    end
  end

  def icon_key(key)
    @icons[key] ||= yield.to_s
    key
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
