# Sources by category (#166, Design's spec): which sources find or confirm
# the companies in each of the 9 categories, and whether any of them runs.
# The list is Data Quality's lookup (config/source_coverage.yml) until #281
# tags records by category; a crawler's status comes from the data.
#
#   coverage = SourceCoverage.new
#   coverage.categories.first.name        # => "Utilities and operators"
#   coverage.categories.first.live_count  # => 2 (of .sources.size)
#   coverage.uncovered_count             # => 8 (categories with no live source)
#   coverage.general                      # => [Source, …] (whole industry)
class SourceCoverage
  FILE = Rails.root.join("config/source_coverage.yml")
  # A crawler is live when it has read something and succeeded this recently.
  LIVE_WITHIN = 3.days
  # Crawlers that read their documents through another source (an API or
  # index): a failure there leaves the documents as they were, so the
  # crawler is live only while that source is healthy too.
  COMPANIONS = { "usaspending_doe_awards" => %w[usaspending_api], "eia_generators" => %w[eia_860m_index], "nrc_fuel_cycle" => %w[nrc_fuel_cycle_index], "nrc_reactor_vendors" => %w[nrc_reactor_list], "nrc_research_reactors" => %w[nrc_research_reactors_index] }.freeze

  Source = Data.define(:name, :status, :issue, :crawler, :kind, :leads, :note, :group, :domain, :documents) do
    def live? = status == "live"
  end

  # documents and facts: what its single-category crawlers have read and
  # back (each fact once); nil ("—") until #281 can tell which records are
  # in it.
  Category = Data.define(:key, :name, :sources, :documents, :facts) do
    def live_count = sources.count(&:live?)
    def live? = live_count.positive?
  end

  def initialize(config = YAML.load_file(FILE))
    @config = config
  end

  def categories
    @categories ||= begin
      entries = @config.fetch("categories")
      # A crawler counts toward a category's documents and facts only when it
      # serves that category alone; DOE awards span several.
      kind_counts = entries.flat_map { |entry| entry["sources"].filter_map { |row| row["kind"] } }.tally
      entries.map do |entry|
        sources = entry.fetch("sources").map { |row| source(row) }
        # Whatever they've read, live or not: freshness is the Coverage column's.
        own = sources.select { |row| row.kind && kind_counts[row.kind] == 1 }.map { |row| catalog[row.kind] }.compact.uniq
        key = entry.fetch("key")
        Category.new(key:, name: display_name(key, entry.fetch("name")), sources:,
          documents: (own.sum(&:documents) if own.any?), facts: (SourceCatalog.facts_backed_by(own.map(&:key)) if own.any?))
      end
    end
  end

  def general = @general ||= @config.fetch("general").map { |row| source(row) }

  def uncovered_count = categories.count { |category| !category.live? }

  private
    def source(row)
      status = row.fetch("status")
      status = live_kinds.include?(row["kind"]) ? "live" : status if row["kind"]
      Source.new(name: row.fetch("name"), status:, issue: row["issue"], crawler: row["crawler"] == true, kind: row["kind"], leads: row["leads"] == true,
        note: row["note"], group: row["group"], domain: row["domain"], documents: (hand_documents(row) if status == "hand"))
    end

    # Crawler kinds that have read something within LIVE_WITHIN: a crawl run
    # that succeeded, and a document it fetched with content and an OK status,
    # with no problem since (a failed fetch keeps the old content but records
    # its reason, Snapshot.take). Re-processing old documents (extract,
    # match, verify), a blocked fetch or a 503 doesn't count.
    def live_kinds
      @live_kinds ||= begin
        since = LIVE_WITHIN.ago
        # Each kind's latest finished crawl: it succeeded, and lately. A newer
        # failed crawl isn't hidden by an earlier success.
        latest = CrawlRun.stage_crawl.where.not(status: "running").select("DISTINCT ON (source_kind) source_kind, status, started_at")
          .order(:source_kind, started_at: :desc, id: :desc)
        crawled = latest.select { |run| run.status == "succeeded" && run.started_at >= since }.map(&:source_kind).to_set
        fetched = ::Source.crawl_ok.where(fetched_at: since.., status_reason: nil)
        read = fetched.where.not(content_sha256: nil).distinct.pluck(:source_kind).to_set
        # A companion is unhealthy when any of its sources has a problem or
        # wasn't fetched lately. It needn't store content itself (the
        # USAspending API's results are stored on the recipients' documents).
        failing = ::Source.where(source_kind: COMPANIONS.values.flatten)
          .where.not(id: fetched.select(:id)).distinct.pluck(:source_kind).to_set
        (crawled & read).select { |kind| latest_read?(kind, fetched) }
          .reject { |kind| COMPANIONS.fetch(kind, []).any? { |companion| failing.include?(companion) } }.to_set
      end
    end

    # Its most recent fetch attempt read something: an older document read
    # fine doesn't make it live when the newest (EIA's new monthly workbook)
    # was blocked.
    def latest_read?(kind, fetched)
      latest_id = ::Source.where(source_kind: kind).where.not(fetched_at: nil).order(fetched_at: :desc, id: :desc).pick(:id)
      latest_id && fetched.where.not(content_sha256: nil).exists?(latest_id)
    end

    def catalog = @catalog ||= SourceCatalog.official.index_by(&:kind)

    # Matched by the bucket's stable slug, never its name, so a rename
    # ("Reactor developers" to "Developers", #322) doesn't break it. Once the
    # app has buckets (::Category.buckets, #322), their names are shown;
    # until then, the lookup's.
    def display_name(key, fallback)
      bucket = ::Category.find(key) if ::Category.respond_to?(:buckets)
      bucket&.name || fallback
    end

    def hand_documents(row)
      return ::Source.where(source_kind: SourceCatalog::RESEARCH_KIND, domain: row["domain"]).count if row["domain"]
      return unless row["group"] # not counted: nothing maps it to documents

      research[row["group"]]&.documents.to_i
    end

    # The Sources page's hand-research groups, read once per page.
    def research = @research ||= SourceCatalog.research.index_by(&:key)
end
