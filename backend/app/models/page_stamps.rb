# Each company and plant page's own change stamp (PM, 3 Nov): a digest of
# everything its page reads, so a change rebuilds only the pages it touches,
# and the warmer (PageWarmJob) rebuilds only those.
#
#   PageStamps.company(42)  # => "9c1f…" (one query)
#   PageStamps.companies    # => { id => stamp } for every published company (one query)
#
# A company page reads: the record and its other names; its roles and
# technologies; its links to companies, and those companies (names, and the
# roles that give them a category); its plant links, the plants and their
# sites; deal terms on any of those; licensing stages; news about it; and the
# evidence on all of these with their sources. A plant page reads the site and
# its units, their other names and technologies, their company links and those
# companies (with their roles), deal terms, licensing stages, news, and the
# evidence and sources. Each part is its latest change and its row count (a
# deletion changes the count); evidence, which has no updated_at, by a
# fingerprint of what pages show from it.
#
# A new section on either page that reads something else must be added here,
# or that part of the page waits for the next deploy or day to update.
# test/integration/page_stamps_coverage_test.rb fails when a page reads a
# record whose change doesn't move its stamp. (Site: a section that reads
# other companies, such as Similar companies, needs its rows here too, or must
# render outside page_cache.)
module PageStamps
  # A page's cache version: its stamp, the deploy and today's date (pages say
  # "Accessed <date>" and read link dates against today).
  # A page's cache version, read from the stamp map the warmer builds once per
  # data change (Infra, 3 Nov: computing a big company's stamp on every visit
  # cost ~0.1-0.5 s on production). Until the map for the current data exists
  # (the minutes after a change), the whole directory's DataVersion stands in:
  # correct at once, just not shared with the warmed copy.
  MAP = "page_stamps/map/v1"
  def self.version(kind, id)
    data = DataVersion.current
    Rails.cache.read([ MAP, data ])&.dig(kind, id) || "data/#{data}"
  end

  # Every page's version for this data, computed once and kept for visits to read: { company: { id => v }, plant: { id => v } }.
  def self.map(data = DataVersion.current)
    Rails.cache.fetch([ MAP, data ], expires_in: 1.day) { { company: versions(:company), plant: versions(:plant) } }
  end

  def self.versions(kind) = public_send(kind == :company ? :companies : :plants).transform_values { |stamp| [ DataVersion::REVISION, Date.current.iso8601, stamp ].join("/") }

  def self.company(id) = Organization.where(id:).pick(Arel.sql(company_sql("organizations.id")))
  def self.plant(id) = Facility.where(id:).pick(Arel.sql(plant_sql("facilities.id")))
  def self.companies = Organization.published.pluck(:id, Arel.sql(company_sql("organizations.id"))).to_h
  def self.plants = Facility.published.where(parent_id: nil).pluck(:id, Arel.sql(plant_sql("facilities.id"))).to_h

  # MAX(updated_at) and COUNT of a table's rows.
  def self.rows(table, where) = "(SELECT concat(MAX(t.updated_at), '/', COUNT(*)) FROM #{table} t WHERE #{where})"

  def self.evidence(pairs)
    where = pairs.map { |type, ids| "(e.subject_type = '#{type}' AND e.subject_id IN (#{ids}))" }.join(" OR ")
    "(SELECT concat(COUNT(*), '/', SUM(hashtext(concat_ws('|', e.id, e.subject_type, e.subject_id, e.source_id, e.quote, e.confidence, " \
      "array_to_string(e.fields, ','), e.last_confirmed_at, s.updated_at)))) FROM evidence e JOIN sources s ON s.id = e.source_id WHERE #{where})"
  end

  # The role and technology names every page labels things with: small tables, read whole.
  LABELS = [ "(SELECT concat(MAX(t.updated_at), '/', COUNT(*)) FROM roles t)", "(SELECT concat(MAX(t.updated_at), '/', COUNT(*)) FROM technologies t)" ].freeze

  SIMILAR = [
    *%w[organizations organization_roles organization_technologies].map { |table| "(SELECT concat(MAX(t.updated_at), '/', COUNT(*)) FROM #{table} t)" },
    # Which companies have their own source (#730: Similar companies shows a peer's HQ only then). Uncorrelated, so
    # Postgres computes it once per query, not once per company.
    "(SELECT concat(COUNT(*), '/', SUM(hashtext(concat_ws('|', e.id, e.subject_id, e.source_id, e.quote)))) FROM evidence e WHERE e.subject_type = 'Organization')"
  ].freeze

  def self.digest(parts) = "md5(concat_ws('|', #{(parts + LABELS).join(', ')}))"

  def self.company_sql(x)
    rels = "SELECT r.id FROM relationships r WHERE r.from_organization_id = #{x} OR r.to_organization_id = #{x}"
    partners = "SELECT CASE WHEN r.from_organization_id = #{x} THEN r.to_organization_id ELSE r.from_organization_id END " \
      "FROM relationships r WHERE r.from_organization_id = #{x} OR r.to_organization_id = #{x}"
    plant_links = "SELECT x.id FROM facility_relationships x WHERE x.organization_id = #{x}"
    plants = "SELECT x.facility_id FROM facility_relationships x WHERE x.organization_id = #{x} " \
      "UNION SELECT f.parent_id FROM facilities f JOIN facility_relationships x ON x.facility_id = f.id WHERE x.organization_id = #{x} AND f.parent_id IS NOT NULL"
    roles = "SELECT y.id FROM organization_roles y WHERE y.organization_id = #{x}"
    partner_roles = "SELECT y.id FROM organization_roles y WHERE y.organization_id IN (#{partners})"
    technologies = "SELECT y.id FROM organization_technologies y WHERE y.organization_id = #{x}"
    deals = "SELECT d.id FROM deal_terms d WHERE (d.link_type = 'Organization' AND d.link_id = #{x}) " \
      "OR (d.link_type = 'Relationship' AND d.link_id IN (#{rels})) OR (d.link_type = 'FacilityRelationship' AND d.link_id IN (#{plant_links}))"
    stages = "SELECT g.id FROM licensing_stages g WHERE g.organization_id = #{x}"
    news = "SELECT m.news_item_id FROM news_mentions m WHERE m.subject_type = 'Organization' AND m.subject_id = #{x}"
    digest([
      rows("organizations", "t.id = #{x}"), rows("organization_aliases", "t.organization_id = #{x}"),
      rows("organization_roles", "t.organization_id = #{x}"), rows("organization_technologies", "t.organization_id = #{x}"),
      rows("relationships", "t.id IN (#{rels})"), rows("organizations", "t.id IN (#{partners})"), rows("organization_roles", "t.id IN (#{partner_roles})"),
      rows("facility_relationships", "t.id IN (#{plant_links})"), rows("facilities", "t.id IN (#{plants})"),
      rows("deal_terms", "t.id IN (#{deals})"), rows("licensing_stages", "t.id IN (#{stages})"),
      rows("news_mentions", "t.subject_type = 'Organization' AND t.subject_id = #{x}"), rows("news_items", "t.id IN (#{news})"),
      # Similar companies (#678) may show any company that shares a role or technology: coarse on purpose (Infra, PM, 3 Nov),
      # the whole tables' latest change and count, so a company page rebuilds when any company, role or technology changes.
      *SIMILAR,
      # Partners' own evidence too: a partner's written line shows only once it has a source (Infra).
      evidence([ [ "Organization", x ], [ "Organization", partners ], [ "Relationship", rels ], [ "OrganizationRole", roles ], [ "OrganizationRole", partner_roles ],
        [ "OrganizationTechnology", technologies ], [ "FacilityRelationship", plant_links ], [ "Facility", plants ], [ "DealTerm", deals ],
        [ "LicensingStage", stages ] ])
    ])
  end

  def self.plant_sql(x)
    places = "SELECT #{x} UNION SELECT u.id FROM facilities u WHERE u.parent_id = #{x}"
    links = "SELECT y.id FROM facility_relationships y WHERE y.facility_id IN (#{places})"
    companies = "SELECT y.organization_id FROM facility_relationships y WHERE y.facility_id IN (#{places})"
    company_roles = "SELECT r.id FROM organization_roles r WHERE r.organization_id IN (#{companies})"
    deals = "SELECT d.id FROM deal_terms d WHERE d.link_type = 'FacilityRelationship' AND d.link_id IN (#{links})"
    stages = "SELECT g.id FROM licensing_stages g WHERE g.facility_id IN (#{places})"
    news = "SELECT m.news_item_id FROM news_mentions m WHERE m.subject_type = 'Facility' AND m.subject_id IN (#{places})"
    technologies = "SELECT u.technology_id FROM facilities u WHERE u.id IN (#{places})"
    digest([
      rows("facilities", "t.id IN (#{places})"), rows("facility_aliases", "t.facility_id IN (#{places})"),
      rows("technologies", "t.id IN (#{technologies})"),
      rows("facility_relationships", "t.id IN (#{links})"), rows("organizations", "t.id IN (#{companies})"),
      rows("organization_roles", "t.id IN (#{company_roles})"),
      rows("deal_terms", "t.id IN (#{deals})"), rows("licensing_stages", "t.id IN (#{stages})"),
      rows("news_mentions", "t.subject_type = 'Facility' AND t.subject_id IN (#{places})"), rows("news_items", "t.id IN (#{news})"),
      evidence([ [ "Facility", places ], [ "Organization", companies ], [ "FacilityRelationship", links ], [ "OrganizationRole", company_roles ], [ "DealTerm", deals ],
        [ "LicensingStage", stages ] ])
    ])
  end
end
