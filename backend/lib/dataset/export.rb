require "csv"
require "json"

# The open dataset's files (#254), as a dry run: every published fact with
# its sources, one CSV and one JSON file per record type, plus a README.
# Nothing here is public until Tosin decides (PRD decision #3, "no export
# yet"): it only writes a folder on the machine that runs it.
#
# Same privacy rules as the site: published facts only (each model's
# .published scope), and only the columns listed below. Nothing internal is
# exported: no verified_by, confidence, crawl state, page text, candidates,
# users or correction reports.
module Dataset
  class Export
    FILES = {
      "companies" => %w[slug name legal_name website description hq_city hq_state country_code founded_year status aliases roles
        technologies checked_on url],
      "plants" => %w[slug name site_slug facility_type status technology reactor_type capacity_mw nrc_docket eia_plant_id city state
        country_code latitude longitude checked_on url],
      "company_links" => %w[id from_company to_company type description started_on ended_on checked_on],
      "plant_links" => %w[id company plant type ownership_pct description started_on ended_on checked_on],
      "sources" => %w[id url title published_on],
      "evidence" => %w[fact_file fact_key source_id quote]
    }.freeze

    def initialize(dir, base_url: "https://nuclear-directory.org")
      @dir = Pathname(dir)
      @base_url = base_url
    end

    # Writes the files and returns { "companies" => 82, … }.
    def write!
      FileUtils.mkdir_p(@dir)
      tables = build
      tables.each do |name, rows|
        CSV.open(@dir.join("#{name}.csv"), "w") do |csv|
          csv << FILES.fetch(name)
          rows.each { |row| csv << FILES.fetch(name).map { |column| csv_value(row[column]) } }
        end
        File.write(@dir.join("#{name}.json"), JSON.pretty_generate(rows))
      end
      counts = tables.transform_values(&:size)
      File.write(@dir.join("README.md"), readme(counts))
      counts
    end

    private
      def build
        companies = Organization.published.includes(:aliases).order(:slug).to_a
        plants = Facility.published.includes(:technology, :parent).order(:slug).to_a
        company_links = Relationship.published.includes(:from_organization, :to_organization).order(:id).to_a
        plant_links = FacilityRelationship.published.includes(:organization, :facility).order(:id).to_a
        roles = OrganizationRole.published.includes(:role).group_by(&:organization_id)
        technologies = OrganizationTechnology.published.includes(:technology).group_by(&:organization_id)

        facts = { "companies" => companies, "plants" => plants, "company_links" => company_links, "plant_links" => plant_links }
        evidence = facts.flat_map do |file, records|
          by_id = records.index_by(&:id)
          Evidence.where(subject: records).order(:id).map do |row|
            subject = by_id.fetch(row.subject_id)
            { "fact_file" => file, "fact_key" => subject.respond_to?(:slug) ? subject.slug : subject.id, "source_id" => row.source_id,
              "quote" => row.quote }
          end
        end

        {
          "companies" => companies.map do |company|
            aliases = company.aliases.map(&:alias).reject { |name| OrganizationAlias.normalize(name) == OrganizationAlias.normalize(company.name) }
            row(company, %w[slug name legal_name website description hq_city hq_state country_code founded_year status]).merge(
              "aliases" => aliases.sort, "roles" => Array(roles[company.id]).map { |r| r.role.key }.sort,
              "technologies" => Array(technologies[company.id]).map { |t| t.technology.key }.sort,
              "checked_on" => company.verified_at&.to_date, "url" => "#{@base_url}/companies/#{company.slug}")
          end,
          "plants" => plants.map do |plant|
            row(plant, %w[slug name facility_type status reactor_type capacity_mw nrc_docket eia_plant_id city state country_code latitude
              longitude]).merge("site_slug" => plant.parent&.slug, "technology" => plant.technology&.key,
              "checked_on" => plant.verified_at&.to_date, "url" => "#{@base_url}/plants/#{plant.slug}")
          end,
          "company_links" => company_links.map do |link|
            row(link, %w[id description started_on ended_on]).merge("from_company" => link.from_organization.slug,
              "to_company" => link.to_organization.slug, "type" => link.relationship_type, "checked_on" => link.verified_at&.to_date)
          end,
          "plant_links" => plant_links.map do |link|
            row(link, %w[id ownership_pct description started_on ended_on]).merge("company" => link.organization.slug,
              "plant" => link.facility.slug, "type" => link.relationship_type, "checked_on" => link.verified_at&.to_date)
          end,
          "sources" => Source.where(id: evidence.map { |item| item["source_id"] }.uniq).order(:id)
            .map { |source| row(source, %w[id url title published_on]) },
          "evidence" => evidence
        }
      end

      def row(record, columns) = columns.index_with { |column| record.public_send(column) }

      def csv_value(value) = value.is_a?(Array) ? value.join("; ") : value

      def readme(counts)
        <<~MD
          # Nuclear Directory open dataset (dry run)

          Every published fact in the Nuclear Directory, with the public source each one comes from. Generated #{Time.current.utc.to_date}.

          | File | Rows |
          |---|---|
          #{counts.map { |name, count| "| `#{name}.csv` / `#{name}.json` | #{count} |" }.join("\n")}

          - `companies` and `plants` are keyed by `slug`, the same as their page URLs. A unit's `site_slug` is the plant it belongs to.
          - `company_links` and `plant_links` are keyed by `id` and name their ends by slug.
          - `evidence` ties each fact (`fact_file`, `fact_key`) to a `sources` row and the quote that supports it.
          - Lists in CSV (`aliases`, `roles`, `technologies`) are separated by "; ".
          - `checked_on` is the date the fact was last checked.

          This is a dry run of the format. It isn't published, and its license and citation (CC BY 4.0, a Zenodo DOI) wait on a decision.
        MD
      end
  end
end
