# The files that describe a dataset release (#254): README, the data
# dictionary, CITATION.cff and .zenodo.json for citing it, the licence
# notice and the changelog. Written from Export::TABLES and docs/DATA.md's
# rules, so they never describe a column the files don't have.
#
# The concept DOI and the author's ORCID come from the environment
# (DATASET_CONCEPT_DOI, DATASET_AUTHOR_ORCID) once they exist; until then
# the files say the DOI comes with the Zenodo archive and leave ORCID out.
module Dataset
  class Docs
    Export = Dataset::Export
    KEYWORDS = [ "nuclear energy", "nuclear industry", "supply chain", "United States", "nuclear power plants", "companies" ].freeze

    # What each link type means (docs/DATA.md, section 2).
    RELATIONSHIP_TYPES = {
      "operates" => "Company to facility. Runs it day to day; for a power reactor, holds the NRC operating license",
      "owns" => "Company to facility. Holds an ownership share; ownership_pct only when the source states it",
      "vendor_for" => "Company to facility. Designed or supplies the reactor",
      "offtakes_from" => "Company to facility. Has agreed to buy the plant's power",
      "supplies" => "Company to company. Provides fuel, equipment or services under a stated agreement",
      "invests_in" => "Company to company. Takes equity",
      "funds" => "Company to company. Grants, awards or cost-shared programs",
      "offtake_with" => "Company to company. Has agreed to buy power from the company's fleet, not one plant",
      "subsidiary_of" => "Company to company. Points from the child to its parent"
    }.freeze

    # What each crawled source is, for the README's method (only those in the release).
    CRAWLED = {
      "nrc_reactor_list" => "NRC's list of power reactors",
      "nrc_power_status" => "NRC's daily power reactor status reports",
      "nrc_decommissioning" => "NRC's list of reactors being decommissioned",
      "eia_generators" => "EIA's monthly generator inventory (EIA-860M)",
      "eia_plants" => "EIA's annual plant file (EIA-860)",
      "usaspending_doe_awards" => "DOE awards on USAspending.gov"
    }.freeze

    def initialize(version:, released_on:, counts:, manifest:, previous:, crawled: [])
      @crawled = CRAWLED.select { |kind, _| crawled.include?(kind) }.values
      @version = version
      @released_on = released_on
      @counts = counts
      @manifest = manifest
      @previous = previous
    end

    def readme
      <<~MD
        # #{Export::TITLE}

        In short: every published fact in [Nuclear Directory](#{Export::SITE}), the companies and facilities of the US nuclear industry and the links between them, with the public documents each fact comes from.

        Version #{@version}, released #{@released_on.iso8601}. #{doi_line}

        ## Files

        Each table is in CSV and JSON. In CSV, lists (aliases, buckets, roles, technologies) are joined with "#{Export::LIST_SEPARATOR}"; in JSON they're arrays. Every column is described in [DATA-DICTIONARY.md](DATA-DICTIONARY.md).

        | Table | Rows | Holds |
        |---|---|---|
        | `companies` | #{@counts["companies"]} | One row per company, by brand |
        | `facilities` | #{@counts["facilities"]} | Sites (power plants, fuel plants, test reactors, mines, fusion plants) and the reactor units under them |
        | `relationships` | #{@counts["relationships"]} | Links between two companies, and companies' roles at facilities |
        | `sources` | #{@counts["sources"]} | The public documents the facts come from |
        | `evidence` | #{@counts["evidence"]} | Which source states each fact |

        ## How it's collected

        1. Crawlers read public records: #{@crawled.any? ? @crawled.to_sentence : "none in this release"}.
        2. People research the rest from companies' own pages, press releases, SEC filings and agency pages.
        3. AI models help: they read pages and propose facts, and a separate model checks each proposal against its quote. Neither publishes anything.

        ## How it's checked

        - Every published fact has a public source and a quote that states it. A fact we can't source isn't published.
        - A person approves every fact before it's published, and a person's decision is not overwritten by a crawler.
        - Sources are official records first (NRC, EIA, DOE, SEC), then the company itself, then named reporting. Aggregators and directories are used as leads, not cited as sources. Power deals, investments and awards need an official record or the parties' own statement.
        - Crawled sources are read again on a schedule; a fact whose source changes or drops it goes back to a person.
        - The full rules are in the project's [data standard](https://github.com/tosinoladokun/nuclear-directory/blob/main/docs/DATA.md).

        ## Limits

        - US only, and not every company or facility in the industry yet.
        - A blank value means no source states it. Nothing is guessed.
        - Capacity is net summer capacity in MW, from EIA, for reactor units. A site's capacity is the sum of its operating units.
        - Buckets are computed from each company's sourced categories and links, so a company can be in several. Count companies, not the sum of buckets.
        - Quotes aren't in this dataset, because they're other publishers' text. Each fact's page on #{Export::SITE.delete_prefix("https://")} shows its quote, and the `sources` table links to every document.
        - The data is as of the release date. The website changes daily.

        ## How to cite

        #{citation_line}

        ## Licence

        #{Export::LICENSE[:name]} ([#{Export::LICENSE[:id]}](#{Export::LICENSE[:url]})). You may share and adapt the data, including commercially, as long as you credit it (see How to cite), link the licence and say whether you made changes. #{Export::LICENSE_SCOPE}

        ## Corrections

        Report a wrong or missing fact from its page on #{Export::SITE.delete_prefix("https://")}, with a link to a public source.
      MD
    end

    def dictionary
      tables = Export::TABLES.map do |table, columns|
        rows = columns.map { |column, about| "| `#{column}` | #{about} |" }.join("\n")
        "## #{table}\n\n| Column | Holds |\n|---|---|\n#{rows}\n"
      end
      <<~MD
        # Data dictionary

        Every column in every table of #{Export::TITLE}, version #{@version}. Dates are ISO 8601 (`2026-10-09`). Values follow the project's [data standard](https://github.com/tosinoladokun/nuclear-directory/blob/main/docs/DATA.md).

        #{tables.join("\n")}
        ## Relationship types

        | Type | Means |
        |---|---|
        #{RELATIONSHIP_TYPES.map { |type, about| "| `#{type}` | #{about} |" }.join("\n")}

        ## Buckets

        | Bucket | Name |
        |---|---|
        #{Category.buckets.map { |category| "| `#{category.key}` | #{category.name} |" }.join("\n")}

        ## Roles

        | Role | Name |
        |---|---|
        #{Role.order(:key).map { |role| "| `#{role.key}` | #{role.name} |" }.join("\n")}

        ## Document types

        | Type | Means |
        |---|---|
        #{Export::DOCUMENT_TYPES.map { |type, about| "| `#{type}` | #{about} |" }.join("\n")}
      MD
    end

    def citation
      author = { "family-names" => Export::AUTHOR[:family], "given-names" => Export::AUTHOR[:given], "orcid" => orcid_url }.compact
      {
        "cff-version" => "1.2.0",
        "message" => "If you use this dataset, please cite it as below.",
        "type" => "dataset",
        "title" => Export::TITLE,
        "version" => @version,
        "date-released" => @released_on.iso8601,
        "authors" => [ author ],
        "license" => Export::LICENSE[:id],
        "url" => Export::SITE,
        "keywords" => KEYWORDS,
        "doi" => concept_doi,
        "preferred-citation" => {
          "type" => "data", "title" => Export::TITLE, "authors" => [ author.dup ], "publisher" => { "name" => Export::PUBLISHER },
          "year" => @released_on.year, "doi" => concept_doi, "url" => (concept_doi ? "https://doi.org/#{concept_doi}" : Export::SITE)
        }.compact
      }.compact.to_yaml.delete_prefix("---\n")
    end

    def zenodo
      creator = { "name" => "#{Export::AUTHOR[:family]}, #{Export::AUTHOR[:given]}", "orcid" => orcid }.compact
      JSON.pretty_generate({
        "title" => Export::TITLE, "upload_type" => "dataset", "version" => @version, "publication_date" => @released_on.iso8601,
        "description" => "Every published fact in Nuclear Directory (#{Export::SITE}): companies and facilities of the US nuclear " \
          "industry and the links between them, with the public documents each fact comes from. #{Export::LICENSE_SCOPE}",
        "creators" => [ creator ], "license" => Export::LICENSE[:id].downcase, "access_right" => "open", "keywords" => KEYWORDS
      })
    end

    def license
      <<~TXT
        #{Export::TITLE}
        Copyright #{@released_on.year} #{Export::AUTHOR[:given]} #{Export::AUTHOR[:family]}

        Licensed under the #{Export::LICENSE[:name]} licence (#{Export::LICENSE[:id]}).
        Summary: #{Export::LICENSE[:url]}
        Legal code: #{Export::LICENSE[:legalcode]}

        You may share and adapt this data for any purpose, including commercially, if you give appropriate credit, link the licence and say whether you made changes.

        #{Export::LICENSE_SCOPE}

        Facts themselves aren't subject to copyright. The licence covers this compilation: its selection, structure and descriptions.
      TXT
    end

    def changelog
      before = @previous&.dig("manifest")
      lines = [ "## #{@version} (#{@released_on.iso8601})", "" ]
      lines << "| Table | Rows | Added | Removed |" << "|---|---|---|---|"
      @counts.each do |table, count|
        old = before ? before.dig("keys", table).to_a : []
        new = @manifest.dig("keys", table)
        lines << "| `#{table}` | #{count} | #{before ? (new - old).size : count} | #{before ? (old - new).size : 0} |"
      end
      lines << "" << (before ? "Compared with #{before["version"]}." : "First release.")
      if before
        %w[companies facilities].each do |table|
          old, new = before.dig("keys", table).to_a, @manifest.dig("keys", table)
          lines << "" << "- New #{table}: #{(new - old).join(', ')}" if (new - old).any?
          lines << "" << "- Removed #{table}: #{(old - new).join(', ')}" if (old - new).any?
        end
      end
      earlier = @previous&.dig("changelog").to_s.sub(/\A# Changelog\s*/, "").strip
      [ "# Changelog", "", *lines, *("\n#{earlier}" if earlier.present?) ].join("\n") + "\n"
    end

    private
      def concept_doi = ENV["DATASET_CONCEPT_DOI"].presence
      def orcid = ENV["DATASET_AUTHOR_ORCID"].presence
      def orcid_url = orcid && "https://orcid.org/#{orcid}"

      def doi_line
        concept_doi ? "DOI: [#{concept_doi}](https://doi.org/#{concept_doi}) (all versions)." : "Each release is archived on Zenodo, which gives it a DOI."
      end

      def citation_line
        doi = concept_doi ? "https://doi.org/#{concept_doi}" : "DOI from Zenodo"
        "#{Export::AUTHOR[:family]}, #{Export::AUTHOR[:given][0]}. (#{@released_on.year}). *#{Export::TITLE}* (Version #{@version}) [Data set]. " \
          "#{Export::PUBLISHER}. #{doi}. Add the date you downloaded it."
      end
  end
end
