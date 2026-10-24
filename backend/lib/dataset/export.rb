require "csv"
require "json"

# The open dataset (#254): every published fact, with the public documents
# it comes from, as one folder ready to commit to the nuclear-directory-data
# repo. Five tables, each as CSV and JSON, and the files that describe them
# (README, DATA-DICTIONARY, CITATION.cff, .zenodo.json, LICENSE, CHANGELOG)
# plus manifest.json, which the next release reads to say what changed.
#
# Same rules as the site: published facts only (each model's .published
# scope), and only the columns in TABLES. Nothing internal is exported: no
# verified_by, confidence, crawl state, page text, candidates, users or
# correction reports. Third-party quote text isn't exported either: the
# evidence table points each fact at its source document, and the site shows
# the quote (Founder's package, 17 Oct 2026).
#
#   Dataset::Export.new(dir, version: "2026.12", previous: old_dir).write!
#   # => { counts: { "companies" => 82, … }, unknown_publishers: ["example.com"] }
module Dataset
  class Export
    TITLE = "Nuclear Directory: US nuclear supply chain dataset".freeze
    AUTHOR = { given: "Tosin", family: "Oladokun" }.freeze
    PUBLISHER = "Nuclear Directory".freeze
    SITE = "https://nuclear-directory.org".freeze
    LICENSE = { id: "CC-BY-4.0", name: "Creative Commons Attribution 4.0 International",
      url: "https://creativecommons.org/licenses/by/4.0/", legalcode: "https://creativecommons.org/licenses/by/4.0/legalcode" }.freeze
    # Word for word, as Tosin set it (17 Oct 2026).
    LICENSE_SCOPE = "This licence covers the data in this repository. The website's code is not covered.".freeze

    # Every exported column, in order, with what it holds. DATA-DICTIONARY.md
    # is written from this, and a test fails if a row has a column it lacks.
    TABLES = {
      "companies" => {
        "slug" => "The company's key, also the end of its page URL. Never reused; a renamed or merged company's old slug redirects",
        "name" => "Display name: the brand the company uses on its own site",
        "legal_name" => "Registered legal name, when a source states it",
        "aliases" => "Other names sources use for it: legal entities, abbreviations, other spellings",
        "website" => "The company's own website",
        "description" => "One or two sentences on what the company does, written by Nuclear Directory from its sources",
        "hq_city" => "Headquarters city, when a source states it",
        "hq_state" => "Headquarters state, as a two-letter USPS code",
        "country_code" => "Country it's based in, ISO 3166 alpha-2, only when a source states it",
        "founded_year" => "Year founded, when a source states it",
        "status" => "active, acquired or defunct",
        "buckets" => "Every industry group its sourced categories and links put it in (see Buckets)",
        "roles" => "Its categories, each from a quote that states it (see Roles)",
        "technologies" => "Technologies it works on: fission, fusion, smr",
        "checked_on" => "Date a person or the verifier last checked it",
        "url" => "Its page on nuclear-directory.org"
      },
      "facilities" => {
        "slug" => "The facility's key, also the end of its page URL",
        "name" => "Display name: the operator's name for the plant; units follow NRC's list (Vogtle 3)",
        "level" => "site (a place) or unit (one reactor under its site)",
        "site_slug" => "For a unit, the slug of its site",
        "facility_type" => "Kind of facility: power_reactor, research_reactor, fuel_facility, enrichment, fusion_facility, uranium_mine, mill or other; blank when not stated",
        "status" => "operating, not_operating, under_construction, planned, shut_down or decommissioning; blank when not stated",
        "technology" => "fission or fusion, when stated",
        "reactor_type" => "Reactor design type as the source states it, e.g. PWR, BWR",
        "capacity_mw" => "Net summer capacity in MW, from EIA-860M. For a unit, its own. For a site, the total of its operating " \
          "units when each is known (blank otherwise); a one-record plant gives its own figure while it operates",
        "nrc_docket" => "NRC docket number, for a licensed reactor",
        "eia_plant_id" => "EIA plant ID, on a site",
        "city" => "City, when a source names it",
        "state" => "State, as a two-letter USPS code",
        "country_code" => "Country, ISO 3166 alpha-2",
        "latitude" => "Latitude, from EIA or an official record, to 6 decimal places",
        "longitude" => "Longitude, from EIA or an official record, to 6 decimal places",
        "checked_on" => "Date a person or the verifier last checked it",
        "url" => "Its page on nuclear-directory.org"
      },
      "relationships" => {
        "id" => "The link's key: company-<n> for a link between companies, facility-<n> for a company's role at a facility",
        "type" => "What the link means (see Relationship types)",
        "from_slug" => "Slug of the company the link starts from (in companies)",
        "to_table" => "companies or facilities: where to_slug is",
        "to_slug" => "Slug of the company or facility the link points to",
        "ownership_pct" => "Ownership share in percent, on owns links, only as stated",
        "description" => "Detail the source gives, e.g. the deal stage (MOU, signed PPA) or the units covered",
        "started_on" => "Date the link began, when stated",
        "ended_on" => "Date the link ended, when stated",
        "checked_on" => "Date a person or the verifier last checked it"
      },
      "sources" => {
        "id" => "The source's key",
        "url" => "Address of the public document",
        "title" => "The document's title",
        "publisher" => "Who publishes it. When it isn't known, its web domain",
        "document_type" => "What kind of document it is (see Document types)",
        "published_on" => "Date the document was published, when known",
        "accessed_on" => "Date Nuclear Directory last read it"
      },
      "evidence" => {
        "fact_table" => "Table of the fact: companies, facilities or relationships",
        "fact_key" => "The fact's slug or id in that table",
        "fact_part" => "For a company's category or technology, which one (role:<key> or technology:<key>); blank for the record or link itself",
        "source_id" => "The source that states it (in sources)"
      }
    }.freeze

    # Lists in CSV are joined with this; JSON keeps them as arrays.
    LIST_SEPARATOR = "; ".freeze

    DOCUMENT_TYPES = {
      "government_dataset" => "A data file an agency publishes, e.g. EIA-860M",
      "regulator_list" => "A list or report a regulator publishes, e.g. NRC's reactor list",
      "award_record" => "A federal award record on USAspending.gov",
      "sec_filing" => "A filing with the U.S. Securities and Exchange Commission",
      "federal_register" => "A Federal Register notice or other U.S. government publication",
      "government_page" => "Another page an agency publishes",
      "company_page" => "A company's own page, press release or report",
      "news_article" => "Named reporting: trade press or news",
      "web_page" => "Any other public page"
    }.freeze
    KIND_TYPES = { "eia_generators" => "government_dataset", "eia_plants" => "government_dataset", "eia_owners" => "government_dataset", "nrc_reactor_list" => "regulator_list",
      "nrc_power_status" => "regulator_list", "nrc_decommissioning" => "regulator_list", "usaspending_doe_awards" => "award_record" }.freeze
    PUBLICATION_HOSTS = %w[federalregister.gov govinfo.gov].freeze

    def initialize(dir, version: Date.current.strftime("%Y.%m"), previous: nil, released_on: Date.current)
      @dir = Pathname(dir)
      @version = version
      @previous = previous && Pathname(previous)
      @released_on = released_on
    end

    # Writes the release and returns what it wrote, and the domains it
    # couldn't name a publisher for.
    def write!
      FileUtils.mkdir_p(@dir)
      tables = build
      tables.each do |name, rows|
        columns = TABLES.fetch(name).keys
        CSV.open(@dir.join("#{name}.csv"), "w") do |csv|
          csv << columns
          rows.each { |row| csv << columns.map { |column| csv_value(row.fetch(column)) } }
        end
        File.write(@dir.join("#{name}.json"), JSON.pretty_generate(rows))
      end
      counts = tables.transform_values(&:size)
      manifest = { "version" => @version, "released_on" => @released_on.iso8601, "counts" => counts,
        "keys" => tables.to_h { |name, rows| [ name, rows.map { |row| key_of(name, row) }.sort ] } }
      previous = read_previous
      write_docs(counts, manifest, previous)
      File.write(@dir.join("manifest.json"), JSON.pretty_generate(manifest))
      File.write(@dir.join("latest.json"), JSON.pretty_generate(latest(counts)))
      { counts:, unknown_publishers: @unknown_publishers.to_a.sort }
    end

    private
      # What the site shows, by the same rules as its pages (CompanyProfile,
      # PlantProfile): a company's own details only when a source backs them;
      # a site's own details only once the site is verified and sourced (a
      # pending site is public through a verified unit); units, links,
      # categories and technologies only with a source. Unsourced records
      # keep their identity row (slug, name, URL) so references still join.
      def build
        companies = Organization.published.includes(:aliases).order(:slug).to_a
        @sourced = Hash.new { |cache, type| cache[type] = Evidence.where(subject_type: type).distinct.pluck(:subject_id).to_set }
        sites = Facility.published.where(parent_id: nil).includes(:technology).order(:slug).to_a
        @profiles = sites.to_h { |site| [ site.id, PlantProfile.new(site) ] }
        # Every published unit of a public site. One with no source of its own
        # is an identity row only (its page lists only sourced units), so a
        # sourced link to it still joins.
        units = Facility.published.where(parent_id: sites.map(&:id)).includes(:technology, :parent).to_a
        sourced_units = units.select { |unit| sourced?(unit) }
        facilities = (sites + units).sort_by(&:slug)
        shown_sites = sites.select { |site| @profiles.fetch(site.id).site_facts? }
        company_links = Relationship.published.includes(:from_organization, :to_organization).order(:id).select { |link| sourced?(link) }
        # A link to a verified site shows even when the site's own details
        # don't (PlantProfile#links): the link has its own source.
        plant_links = FacilityRelationship.published.where(facility_id: [ *units, *sites.select(&:verified?) ].map(&:id))
          .includes(:organization, :facility).order(:id).select { |link| sourced?(link) }
        roles = OrganizationRole.published.includes(:role, :organization).where(organization_id: companies.map(&:id)).select { |r| sourced?(r) }
        technologies = OrganizationTechnology.published.includes(:technology, :organization).where(organization_id: companies.map(&:id))
          .select { |t| sourced?(t) }
        buckets = Category.buckets.map { |category| [ category.key, Organization.where(id: Bucket.organization_ids(category)).pluck(:id).to_set ] }

        evidence = evidence_rows(companies: companies.select { |c| sourced?(c) }, facilities: [ *shown_sites, *sourced_units ], company_links:,
          plant_links:, roles:, technologies:)
        sources = Source.where(id: evidence.map { |row| row["source_id"] }.uniq).order(:id).to_a

        {
          "companies" => companies.map { |company| company_row(company, roles, technologies, buckets) },
          "facilities" => facilities.map { |facility| facility_row(facility) },
          "relationships" => company_links.map { |link| company_link_row(link) } + plant_links.map { |link| plant_link_row(link) },
          "sources" => source_rows(sources),
          "evidence" => evidence
        }
      end

      def sourced?(record) = @sourced[record.class.polymorphic_name].include?(record.id)

      COMPANY_DETAILS = %w[legal_name website description hq_city hq_state country_code founded_year].freeze

      def company_row(company, roles, technologies, buckets)
        own = OrganizationAlias.normalize(company.name)
        details = sourced?(company)
        {
          **row(company, %w[slug name]), "legal_name" => (company.legal_name if details),
          "aliases" => details ? company.aliases.map(&:alias).reject { |name| OrganizationAlias.normalize(name) == own }.sort : [],
          **row(company, COMPANY_DETAILS - %w[legal_name]).transform_values { |value| value if details },
          "status" => (company.status if details),
          "buckets" => buckets.filter_map { |key, ids| key if ids.include?(company.id) },
          "roles" => roles.select { |r| r.organization_id == company.id }.map { |r| r.role.key }.sort,
          "technologies" => technologies.select { |t| t.organization_id == company.id }.map { |t| t.technology.key }.sort,
          "checked_on" => company.verified_at&.to_date, "url" => "#{SITE}/companies/#{company.slug}"
        }
      end

      SITE_DETAILS = %w[facility_type status reactor_type nrc_docket eia_plant_id city state latitude longitude].freeze

      # A site's details as its page shows them, and its capacity as the page
      # computes it (operating units, or a standalone reactor's own figure
      # while operating). A unit's own values, when it has its own source.
      def facility_row(facility)
        profile = @profiles[facility.id] unless facility.parent_id
        details = profile ? profile.site_facts? : sourced?(facility)
        values = row(facility, SITE_DETAILS).transform_values { |value| value if details }
        {
          **row(facility, %w[slug name]), "level" => facility.parent_id ? "unit" : "site", "site_slug" => facility.parent&.slug,
          "facility_type" => values["facility_type"], "status" => values["status"], "technology" => (facility.technology&.key if details),
          "reactor_type" => values["reactor_type"], "capacity_mw" => profile ? profile.capacity_mw : (facility.capacity_mw if details),
          **values.slice(*%w[nrc_docket eia_plant_id city state]), "country_code" => (facility.country_code if details),
          **values.slice("latitude", "longitude"),
          "checked_on" => (profile ? profile.verified_at : facility.verified_at)&.to_date, "url" => "#{SITE}/plants/#{(facility.parent || facility).slug}"
        }
      end

      def company_link_row(link)
        { "id" => "company-#{link.id}", "type" => link.relationship_type, "from_slug" => link.from_organization.slug,
          "to_table" => "companies", "to_slug" => link.to_organization.slug, "ownership_pct" => nil,
          **row(link, %w[description started_on ended_on]), "checked_on" => link.verified_at&.to_date }
      end

      def plant_link_row(link)
        { "id" => "facility-#{link.id}", "type" => link.relationship_type, "from_slug" => link.organization.slug,
          "to_table" => "facilities", "to_slug" => link.facility.slug, **row(link, %w[ownership_pct description started_on ended_on]),
          "checked_on" => link.verified_at&.to_date }
      end

      # One row per fact and source: which document states each record, link,
      # category and technology. Quotes stay on the site.
      def evidence_rows(companies:, facilities:, company_links:, plant_links:, roles:, technologies:)
        facts = [
          [ companies, "companies", ->(c) { c.slug }, ->(_) { nil } ],
          [ facilities, "facilities", ->(f) { f.slug }, ->(_) { nil } ],
          [ company_links, "relationships", ->(l) { "company-#{l.id}" }, ->(_) { nil } ],
          [ plant_links, "relationships", ->(l) { "facility-#{l.id}" }, ->(_) { nil } ],
          [ roles, "companies", ->(r) { r.organization.slug }, ->(r) { "role:#{r.role.key}" } ],
          [ technologies, "companies", ->(t) { t.organization.slug }, ->(t) { "technology:#{t.technology.key}" } ]
        ]
        facts.flat_map do |records, table, key, part|
          next [] if records.empty?

          by_id = records.index_by(&:id)
          Evidence.where(subject: records).distinct.pluck(:subject_id, :source_id).map do |subject_id, source_id|
            record = by_id.fetch(subject_id)
            { "fact_table" => table, "fact_key" => key.(record), "fact_part" => part.(record), "source_id" => source_id }
          end
        end.uniq.sort_by { |row| [ row["fact_table"], row["fact_key"], row["fact_part"].to_s, row["source_id"] ] }
      end

      def source_rows(sources)
        @source_kinds = sources.map(&:source_kind).to_set
        first_cited = Evidence.where(source_id: sources.map(&:id)).group(:source_id).minimum(:created_at)
        sources.map do |source|
          publisher, kind = publisher_for(host_of(source), source.url)
          { **row(source, %w[id url title]), "publisher" => publisher, "document_type" => document_type(source, kind),
            "published_on" => source.published_on, "accessed_on" => (source.fetched_at || first_cited[source.id])&.to_date }
        end
      end

      def host_of(source) = (source.domain.presence || URI.parse(source.url).host.to_s).downcase.delete_prefix("www.")

      # [name, kind]: a shared host's path rule from the reviewed list first
      # ("content.govdelivery.com/accounts/USDOEINL/"), then the list and a
      # published company's own domain, each trying the host and then its
      # parents. Unknown: the domain itself, listed in the report.
      def publisher_for(host, url)
        @unknown_publishers ||= Set.new
        page = URI.parse(url).then { |uri| "#{uri.host.to_s.downcase.delete_prefix('www.')}#{uri.path}" } rescue ""
        by_path = publishers.select { |key, _| key.include?("/") }.max_by { |key, _| page.start_with?(key) ? key.size : -1 }
        return by_path.last.values_at("name", "kind") if by_path && page.start_with?(by_path.first)

        candidates = host.split(".").each_index.map { |i| host.split(".").drop(i).join(".") }.select { |name| name.include?(".") }
        candidates.each do |name|
          listed = publishers[name] and return [ listed["name"], listed["kind"] ]
          company = company_domains[name] and return [ company, "company" ]
        end
        @unknown_publishers << host
        [ host, nil ]
      end

      def document_type(source, kind)
        KIND_TYPES[source.source_kind] || begin
          host = host_of(source)
          if host == "sec.gov" || host.end_with?(".sec.gov") then "sec_filing"
          elsif PUBLICATION_HOSTS.any? { |name| host == name || host.end_with?(".#{name}") } then "federal_register"
          else { "agency" => "government_page", "company" => "company_page", "news" => "news_article" }.fetch(kind, "web_page")
          end
        end
      end

      def publishers = @publishers ||= YAML.load_file(Rails.root.join("lib/dataset/publishers.yml"))

      def company_domains
        @company_domains ||= Organization.published.where.not(domain: [ nil, "" ]).pluck(:domain, :name)
          .to_h { |domain, name| [ domain.downcase.delete_prefix("www."), name ] }
      end

      def row(record, columns) = columns.index_with { |column| record.public_send(column) }

      def csv_value(value) = value.is_a?(Array) ? value.join(LIST_SEPARATOR) : value

      def key_of(table, row)
        table == "evidence" ? row.values_at("fact_table", "fact_key", "fact_part", "source_id").join("|") : row.fetch(TABLES.fetch(table).keys.first).to_s
      end

      # What the site's /data page reads (#185): this release's version, date,
      # counts and file links, at a stable path on the data repo's default
      # branch. The version DOI exists only once Zenodo has archived the
      # release, so it's blank until the monthly job fills it in.
      DATA_REPO = "tosinoladokun/nuclear-directory-data".freeze

      def latest(counts)
        base = "https://raw.githubusercontent.com/#{DATA_REPO}/v#{@version}"
        { "version" => @version, "released_on" => @released_on.iso8601, "doi" => ENV["DATASET_VERSION_DOI"].presence,
          "concept_doi" => ENV["DATASET_CONCEPT_DOI"].presence, "counts" => counts,
          "files" => counts.keys.to_h { |table| [ table, { "csv" => "#{base}/#{table}.csv", "json" => "#{base}/#{table}.json" } ] } }
      end

      def read_previous
        path = @previous&.join("manifest.json")
        return unless path&.exist?

        { "manifest" => JSON.parse(path.read), "changelog" => @previous.join("CHANGELOG.md").then { |file| file.exist? ? file.read : nil } }
      end

      def write_docs(counts, manifest, previous)
        docs = Docs.new(version: @version, released_on: @released_on, counts:, manifest:, previous:, crawled: @source_kinds.to_a)
        File.write(@dir.join("README.md"), docs.readme)
        File.write(@dir.join("DATA-DICTIONARY.md"), docs.dictionary)
        File.write(@dir.join("CITATION.cff"), docs.citation)
        File.write(@dir.join(".zenodo.json"), docs.zenodo)
        File.write(@dir.join("LICENSE"), docs.license)
        File.write(@dir.join("CHANGELOG.md"), docs.changelog)
      end
  end
end
