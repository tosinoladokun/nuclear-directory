# The admin's Sources (#201 part 2b, Design's spec on #166): every source
# document, grouped the way a person thinks of them. Official records are one
# row per crawler kind; hand research (web pages) is one row per publisher
# group (Data Quality's list of domains, 16 Oct). Each row and document has
# the facts it backs (approved and public), when it was last read and its
# status, the worst of its documents'.
#
#   SourceCatalog.official                 # => [Entry, …] (NRC reactor list, EIA-860M generators, …)
#   SourceCatalog.research                 # => [Entry, …] (Company sites 108, …)
#   SourceCatalog.entry("company-sites")   # => Entry, or nil
#   SourceCatalog.documents("company-sites") # => [Document, …]
#   SourceCatalog.search("cfs")            # => [Document, …]
class SourceCatalog
  Entry = Data.define(:key, :name, :note, :kind, :documents, :facts, :last_read_at, :status, :soon)
  Document = Data.define(:id, :kind, :url, :title, :domain, :group, :facts, :last_read_at, :status, :status_reason) do
    def research? = kind == SourceCatalog::RESEARCH_KIND
    # Its row on Sources: its publisher group, or its crawler kind.
    def entry_key = research? ? group : kind
    # What a person reads for it: its title, else its path, else "/ (home page)".
    def text
      return title if title.present?

      path = URI.parse(url).path.to_s
      path.empty? || path == "/" ? "/ (home page)" : path
    rescue URI::InvalidURIError
      url
    end
  end

  # Crawler kinds, as the admin names them, in this order. note: what it's for, when it backs no facts itself.
  # daily: the daily crawl reads it, so before its first read it's "Not read yet", not Soon.
  OFFICIAL = {
    "nrc_reactor_list" => { name: "NRC reactor list", daily: true },
    "eia_generators" => { name: "EIA-860M generators", daily: true },
    "nrc_power_status" => { name: "NRC power status", note: "cross-check only", daily: true },
    "eia_860m_index" => { name: "EIA-860M index", note: "finds the monthly file", daily: true },
    "usaspending_doe_awards" => { name: "USAspending", daily: true },
    "usaspending_api" => { name: "USAspending API", note: "the award search", daily: true },
    "nrc_decommissioning" => { name: "NRC decommissioning list", daily: true },
    "doe_isotope_sites" => { name: "DOE Isotope Program sites", daily: true },
    "nrc_uranium_recovery" => { name: "NRC uranium recovery sites", daily: true },
    "sec_form_d" => { name: "SEC Form D rounds", daily: true },
    "sec_submissions" => { name: "SEC filing lists", note: "finds each company's Form D filings; the ticker-to-CIK list", daily: true },
    "company_newsrooms" => { name: "Company newsrooms (RSS)", daily: true },
    "federal_register_nrc" => { name: "NRC notices (Federal Register)", daily: true },
    "federal_register_index" => { name: "Federal Register API", note: "finds the NRC's notices", daily: true },
    "trade_press" => { name: "Trade press (leads)", note: "leads for Data Quality, never cited", daily: true },
    "nrc_reactor_vendors" => { name: "NRC reactor vendors (unit pages)", daily: true },
    "doe_programs" => { name: "DOE program pages", daily: true },
    "nrc_research_reactors" => { name: "NRC research and test reactors", daily: true },
    "nrc_research_reactors_index" => { name: "NRC non-power reactor locations", note: "finds each reactor's page", daily: true },
    "nrc_fuel_cycle" => { name: "NRC fuel cycle facilities", daily: true },
    "nrc_fuel_cycle_index" => { name: "NRC fuel cycle locations", note: "finds each facility's page", daily: true },
    # The annual plant file (#319): read once a year, not by the daily crawl.
    "eia_plants" => { name: "EIA-860 plants" },
    "eia_owners" => { name: "EIA-860 owners" },
    "eia_860_index" => { name: "EIA-860 index", note: "finds the yearly file" }
  }.freeze
  RESEARCH_KIND = "web_page"
  LIVE_TYPES = %w[Organization Facility Relationship FacilityRelationship].freeze

  GROUPS = {
    "company-sites" => "Company sites", "news" => "News and trade press", "government" => "Government",
    "sec-filings" => "SEC filings", "nrc-pages" => "NRC pages"
  }.freeze
  # Data Quality's lookup (16 Oct, #166). Anything else is a company site,
  # or Government when it's a .gov domain.
  DOMAIN_GROUPS = {
    "nrc.gov" => "nrc-pages", "sec.gov" => "sec-filings",
    "energy.gov" => "government", "osti.gov" => "government", "content.govdelivery.com" => "government", "bpa.gov" => "government",
    "fs.usda.gov" => "government", "govinfo.gov" => "government", "neutrons.ornl.gov" => "government",
    "public-inspection.federalregister.gov" => "government",
    "world-nuclear-news.org" => "news", "ans.org" => "news", "powermag.com" => "news", "bicmagazine.com" => "news", "businessreport.com" => "news"
  }.freeze

  # Worst first: a group's status is its worst document's.
  STATUS_ORDER = %w[needs_human blocked pending ok].freeze

  class << self
    def group_of(domain)
      domain = domain.to_s.downcase.delete_prefix("www.")
      DOMAIN_GROUPS[domain] || (domain.end_with?(".gov") ? "government" : "company-sites")
    end

    def official
      kinds = Source.where.not(source_kind: RESEARCH_KIND).distinct.pluck(:source_kind)
      (OFFICIAL.keys + (kinds - OFFICIAL.keys)).filter_map do |kind|
        sources = Source.where(source_kind: kind)
        # A crawler that hasn't run yet shows as Soon; an unknown kind only when it has documents.
        next if sources.none? && !OFFICIAL.key?(kind)

        entry_for(kind, OFFICIAL.dig(kind, :name) || kind.humanize, sources, kind:, note: OFFICIAL.dig(kind, :note))
      end
    end

    def research
      by_group = Source.where(source_kind: RESEARCH_KIND).pluck(:id, :domain).group_by { |_, domain| group_of(domain) }
      GROUPS.filter_map do |key, name|
        ids = by_group.fetch(key, []).map(&:first)
        next if ids.empty?

        entry_for(key, name, Source.where(id: ids))
      end.sort_by { |entry| -entry.documents }
    end

    def entry(key) = (official + research).find { |row| row.key == key }

    # Every document under a row (a kind or a publisher group), with its counts.
    def documents(key)
      scope = OFFICIAL.key?(key) || Source.exists?(source_kind: key) && key != RESEARCH_KIND ? Source.where(source_kind: key) : research_scope(key)
      documents_for(scope)
    end

    # Documents whose title, address or domain contains the words, ignoring case.
    def search(query)
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
      documents_for(Source.where("sources.title ILIKE :p OR sources.url ILIKE :p OR sources.domain ILIKE :p", p: pattern))
    end

    def total = Source.count

    # Source ids under a row's key, or a single document ("doc-12"), for Live's filter.
    # How many published facts these rows (crawler kinds or groups) back
    # together, each fact once however many of them back it.
    def facts_backed_by(keys) = public_facts(keys.flat_map { |key| source_ids(key) }.uniq).map { |_, type, id| [ type, id ] }.uniq.size

    def source_ids(key)
      return Source.where(id: key.delete_prefix("doc-").to_i).ids if key.to_s.start_with?("doc-")
      return Source.where(source_kind: key).ids if OFFICIAL.key?(key) || (Source.exists?(source_kind: key) && key != RESEARCH_KIND)

      research_scope(key).ids
    end

    # How a row or document is named in Live's "from" chip.
    def label(key)
      return "#{documents_for(Source.where(id: key.delete_prefix('doc-').to_i)).first&.text}" if key.to_s.start_with?("doc-")

      OFFICIAL.dig(key, :name) || GROUPS[key] || key.to_s.humanize
    end

    # The last finished match runs of a kind, newest first: [CrawlRun, …].
    # The newest crawl, extract or match run of this kind that failed after
    # its last good match (so the match counts shown are an earlier run's), or nil.
    def failure(kind)
      return unless kind

      good = CrawlRun.where(source_kind: kind, stage: "match", status: "succeeded").maximum(:started_at)
      failed = CrawlRun.where(source_kind: kind, stage: %w[crawl extract match], status: "failed")
      (good ? failed.where("started_at > ?", good) : failed).order(started_at: :desc).first
    end

    def runs(kind, limit: 10) = CrawlRun.where(source_kind: kind, stage: "match").where.not(status: "running").order(started_at: :desc).limit(limit)

    private
      def research_scope(key)
        return Source.none unless GROUPS.key?(key)

        ids = Source.where(source_kind: RESEARCH_KIND).pluck(:id, :domain).select { |_, domain| group_of(domain) == key }.map(&:first)
        Source.where(id: ids)
      end

      def entry_for(key, name, sources, kind: nil, note: nil)
        statuses = sources.distinct.pluck(:crawl_status)
        Entry.new(key:, name:, note:, kind:, documents: sources.count, facts: public_facts(sources.ids).uniq { |_, type, id| [ type, id ] }.size,
          last_read_at: sources.maximum(:fetched_at), status: STATUS_ORDER.find { |status| statuses.include?(status) },
          soon: sources.none? && !OFFICIAL.dig(kind, :daily))
      end

      def documents_for(scope)
        # Only what a Document shows: a fetched body (up to 20 MB) is never read here.
        sources = scope.select(:id, :source_kind, :url, :title, :domain, :fetched_at, :crawl_status, :status_reason).order(:domain, :url).to_a
        facts = facts_backed(sources.map(&:id))
        sources.map do |source|
          Document.new(id: source.id, kind: source.source_kind, url: source.url, title: source.title, domain: source.domain, group: group_of(source.domain),
            facts: facts.fetch(source.id, 0), last_read_at: source.fetched_at, status: source.crawl_status, status_reason: source.status_reason)
        end
      end

      # Public facts each source backs: { source_id => count }.
      def facts_backed(source_ids) = public_facts(source_ids).group_by(&:first).transform_values(&:size)

      # [source_id, type, id] for each public fact these sources back.
      # Public facts of the kinds Live lists (companies, plants, reactors and
      # links), so a Facts count opens to that many records there; a role or
      # technology is shown on its company instead.
      def public_facts(source_ids)
        return [] if source_ids.empty?

        rows = Evidence.where(source_id: source_ids, subject_type: LIVE_TYPES).distinct.pluck(:source_id, :subject_type, :subject_id)
        public_ids = rows.group_by { |_, type, _| type }.to_h do |type, typed|
          [ type, type.constantize.published.where(id: typed.map(&:last)).pluck(:id).to_set ]
        end
        rows.select { |_, type, id| public_ids[type].include?(id) }
      end
  end
end
