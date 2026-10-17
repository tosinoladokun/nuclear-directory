# A small public summary of the directory as JSON (#193), for other sites
# (Tosin's own, first) to show live counts: GET /api/snapshot.json.
#
#   DirectorySnapshot.current(base_url: "https://nuclear-directory.org")
#
# Only what the site already shows: published companies and sites, their
# names and page links, the buckets that list a company plus Plants and
# sites (Category, #281) with the same counts as the directory's pills, and
# when each was published.
#
# The shape is a public contract: fields may be added, never renamed or
# removed (the test pins it).
#
# Counting rule: totalEntries is published companies plus published sites,
# each counted once. A category counts its own entries, and a company can be
# in several categories (a utility that also invests) or in none, so the
# category counts needn't add up to totalEntries. Each count is at most
# totalEntries, and "Plants and sites" counts every published site.
#
# Built once and kept in this process's memory: requests never touch the
# database. Any change to a fact (publishing, unpublishing, a crawl's
# writes) clears it (Verifiable), and it expires after TTL in case a change
# was made from another process, such as a console.
class DirectorySnapshot
  TTL = 10.minutes
  RECENT = 5
  EXAMPLES = 2
  CACHE = ActiveSupport::Cache::MemoryStore.new(size: 1.megabyte)
  KEY = "directory_snapshot/v1"

  # The generation is read before building and is part of the key, so a
  # snapshot built while a fact changed is stored under the old generation
  # and never served after the change.
  @generation = 0
  @lock = Mutex.new

  def self.current(base_url:)
    CACHE.fetch([ KEY, generation, base_url ], expires_in: TTL) { new(base_url:).as_json }
  end

  def self.generation = @lock.synchronize { @generation }

  # Called after any fact is saved or deleted (Verifiable). Also records the
  # time durably (the app's database-backed cache), so updatedAt moves
  # forward for a deletion and survives a restart.
  def self.expire!(changed_at: Time.current)
    # The time first: a build under the new generation must already see it.
    CHANGES.write(CHANGED_AT, changed_at.to_f)
    @lock.synchronize { @generation += 1 }
    CACHE.clear
  end

  # The app's cache in production; tests use their own, since the test
  # cache keeps nothing.
  CHANGES = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache
  CHANGED_AT = "directory_snapshot/changed_at"

  def initialize(base_url:)
    @urls = Rails.application.routes.url_helpers
    @url_options = { host: URI(base_url).host, protocol: URI(base_url).scheme, port: URI(base_url).port }
  end

  def as_json(*)
    {
      updatedAt: updated_at.utc.iso8601,
      totalEntries: companies.count + sites.count,
      categories: Category.all.map { |category| category_json(category) }.reject { |json| json[:count].zero? && json[:slug] != "plants" },
      recentlyAdded: recently_added
    }
  end

  private
    def companies = Organization.published
    def sites = DirectoryListing.new.public_sites

    def category_json(category)
      listing = DirectoryListing.new(category: category.key, sort: "connections")
      scope = category.plants ? listing.plant_scope : listing.company_scope
      examples = (category.plants ? listing.plants : listing.companies).limit(EXAMPLES).map(&:name)
      { slug: category.key, name: category.name, count: scope.count,
        url: @urls.companies_url(category: category.key, **@url_options), examples: }
    end

    # Newest first by the date each was published. A site made public by its
    # first published unit (#73) dates from that unit.
    def recently_added
      company_rows = companies.where.not(verified_at: nil).order(verified_at: :desc, id: :desc).limit(RECENT)
        .map { |company| [ company.verified_at, company.name, company_category(company), @urls.company_url(company.slug, **@url_options) ] }
      site_rows = sites.select("facilities.*", "(#{site_published_sql}) AS published_at")
        .order(Arel.sql("published_at DESC NULLS LAST"), id: :desc).limit(RECENT)
        .filter_map do |site|
          next unless site.published_at

          [ site.published_at, site.name, plants_category.name, @urls.plant_url(site.slug, **@url_options) ]
        end

      (company_rows + site_rows).sort_by { |at, name, *| [ -at.to_f, name ] }.first(RECENT)
        .map { |at, name, category, url| { name:, category:, url:, addedAt: at.to_date.iso8601 } }
    end

    # Sites here are public, so their verified units are published. The
    # earlier of the site's own date and its first unit's (LEAST skips nulls).
    def site_published_sql
      "LEAST(facilities.verified_at, (SELECT MIN(units.verified_at) FROM facilities units " \
        "WHERE units.parent_id = facilities.id AND units.verification_status = 'verified'))"
    end

    # The first category, in display order, that lists the company; "Companies"
    # when none does.
    def company_category(company)
      category = company_categories.find { |candidate| candidate_ids(candidate).include?(company.id) }
      category ? category.name : "Companies"
    end

    def company_categories = Category.all.reject(&:plants)
    def plants_category = Category.all.find(&:plants)

    def candidate_ids(category)
      (@category_ids ||= {})[category.key] ||= DirectoryListing.new(category: category.key).company_scope.pluck(:id).to_set
    end

    # The last change to any fact that feeds the snapshot, published or not,
    # so taking something down moves it forward too. The audit log is
    # append-only, so a deleted fact's last change still counts. Always a
    # time: an empty directory reports when the snapshot was built.
    FACT_MODELS = [ Organization, Facility, OrganizationRole, OrganizationTechnology, Relationship, FacilityRelationship,
      VerificationEvent ].freeze

    def updated_at
      recorded = CHANGES.read(CHANGED_AT)&.then { |seconds| Time.zone.at(seconds) }
      times = FACT_MODELS.filter_map { |model| model.maximum(model == VerificationEvent ? :created_at : :updated_at) }
      [ *times, recorded ].compact.max || Time.current
    end
end
