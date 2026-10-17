module DeployData
  # Counts read before and after the data step, so the report shows what it
  # did and a rehearsal on a restored backup can be compared line for line.
  module Census
    # Tables the seed and data migrations write.
    TABLES = %w[organizations organization_aliases organization_roles organization_technologies relationships
      facilities facility_aliases facility_relationships former_slugs evidence sources roles technologies].freeze

    # Data Quality's rule for the reactor count. Filtered by the statuses the
    # app has, since an unknown enum value would match units with no status.
    REACTOR_STATUSES = %w[operating not_operating].freeze

    module_function

    def rows
      connection = ActiveRecord::Base.connection
      TABLES.index_with { |table| connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(table)}").to_i }
    end

    # What the public sees, as Data Quality counts it (docs/DATA.md and the
    # launch posts), from the site's .published scopes: facts are every
    # published record and link (Directory::Lookup.published_counts), reactors
    # are published units with an NRC docket (a site-less one included) that
    # are operating or not operating (#312's decommissioning units aren't), and
    # quotes and sources are those of published facts only, not of pending
    # crawler records.
    def public_totals
      quotes = Directory::Lookup::FACT_TYPES.map do |type|
        Evidence.where(subject_type: type, subject_id: type.constantize.published.select(:id))
      end.reduce(:or)
      {
        "companies" => Organization.published.count,
        "plants and sites" => DirectoryListing.new.public_sites.count,
        "reactors" => Facility.published.where.not(nrc_docket: [ nil, "" ]).where(status: REACTOR_STATUSES & Facility.statuses.keys).count,
        "facts" => Directory::Lookup.published_counts.values.sum,
        "quotes" => quotes.count,
        "sources" => quotes.distinct.count(:source_id)
      }
    end

    def last_event_id = VerificationEvent.maximum(:id).to_i
  end
end
