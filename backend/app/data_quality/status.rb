# How the pipeline is doing, as plain values: for the admin's Sources and
# runs page (#86) and the text report (StatusReport, data_quality:status).
#
#   DataQuality::Status.sources        # => SourceCounts
#   DataQuality::Status.runs           # => Runs (last per stage, running now)
#   DataQuality::Status.spend          # => Spend (this month against the budget)
module DataQuality::Status
  SourceCounts = Data.define(:total, :by_status, :attention)
  # A source that needs a person: blocked (with the CDN reference) or needs_human.
  SourceItem = Data.define(:id, :url, :title, :source_kind, :crawl_status, :status_reason, :fetched_at, :blocked_streak)
  Runs = Data.define(:latest, :running)
  RunItem = Data.define(:id, :source_kind, :stage, :status, :started_at, :finished_at, :stats, :error, :model) do
    def duration = finished_at && (finished_at - started_at).round(1)
    def failed? = status == "failed"
  end
  Spend = Data.define(:calls, :total_tokens, :cost, :budget) do
    # A budget of 0 refuses every call (Budget.check!), so it reads as used up.
    def share = budget.to_f.positive? ? (cost.to_f / budget.to_f) : 1.0
  end

  # One kind of source as the admin's Sources table shows it (#201).
  # last_read_at: its last finished crawl; read and same: rows its last match
  # compared and found unchanged (#240), nil before any; changed: claims
  # waiting in Checks; approved, rejected: claims decided, ever; live:
  # public facts it backs (only with live: true, for Sources; it costs a count per fact type).
  SourceRow = Data.define(:source_kind, :last_read_at, :failed, :read, :same, :changed, :approved, :rejected, :live)

  ATTENTION = %w[blocked needs_human].freeze

  # A row per kind of source that has run or has claims, by last read.
  # within: only match runs started then count for Read and Same (Today's
  # crawl window): none then gives no counts, not an older night's.
  def self.by_kind(live: false, within: nil, directory: DataQuality::DirectoryClient.new)
    crawls = latest(CrawlRun.where(stage: "crawl"))
    matches = latest(CrawlRun.where(stage: "match").then { |runs| within ? runs.where(started_at: within) : runs })
    claims = ->(scope) { Candidate.where(id: scope.select(:id)).joins(:source).group("sources.source_kind").count }
    waiting = claims.call(Candidate.where(id: Candidate.recommended.select(:id)).or(Candidate.status_needs_review))
    approved = claims.call(Candidate.status_merged)
    rejected = claims.call(Candidate.status_rejected)
    kinds.map do |kind|
      crawl = crawls[kind]
      match = matches[kind]&.stats.to_h
      SourceRow.new(source_kind: kind, last_read_at: crawl&.started_at, failed: crawl&.status == "failed",
        read: match["candidates"], same: (match["confirmed"].to_i if match.any?), changed: waiting.fetch(kind, 0),
        approved: approved.fetch(kind, 0), rejected: rejected.fetch(kind, 0),
        live: (directory.published_count_backed_by(source_ids: ::Source.where(source_kind: kind).ids) if live))
    end.sort_by { |row| [ row.last_read_at ? 0 : 1, -row.last_read_at.to_i, row.source_kind ] }
  end

  # Rows every source's match runs compared today, and how many of them
  # still matched (#240): { read: 444, same: 438 }.
  def self.read_today(now: Time.current)
    stats = CrawlRun.where(stage: "match", status: "succeeded", started_at: now.all_day).pluck(:stats)
    { read: stats.sum { |s| s["candidates"].to_i }, same: stats.sum { |s| s["confirmed"].to_i } }
  end

  # Kinds of source that have run or have claims, for by_kind and counting.
  def self.kinds
    (CrawlRun.distinct.pluck(:source_kind) + ::Source.where(id: Candidate.select(:source_id)).distinct.pluck(:source_kind)).uniq.sort
  end

  # The last finished run per kind: { "nrc_reactor_list" => CrawlRun }.
  def self.latest(scope)
    scope.where.not(status: "running").select("DISTINCT ON (source_kind) *").order(:source_kind, started_at: :desc).index_by(&:source_kind)
  end
  private_class_method :latest

  def self.sources
    attention = ::Source.where(crawl_status: ATTENTION).order(:source_kind, :url).map do |source|
      SourceItem.new(id: source.id, url: source.url, title: source.title, source_kind: source.source_kind,
        crawl_status: source.crawl_status, status_reason: source.status_reason, fetched_at: source.fetched_at,
        blocked_streak: source.blocked_streak)
    end
    SourceCounts.new(total: ::Source.count, by_status: ::Source.group(:crawl_status).count.sort.to_h, attention:)
  end

  # Finished runs only in latest; a run in progress is listed under running
  # and mustn't hide its stage's last result.
  def self.runs
    latest = CrawlRun.where.not(status: "running")
      .select("DISTINCT ON (source_kind, stage) *").order(:source_kind, :stage, started_at: :desc)
    Runs.new(latest: latest.map { |run| run_item(run) }, running: CrawlRun.running.order(:started_at).map { |run| run_item(run) })
  end

  # The same month-split totals the budget guard uses.
  def self.spend(now: Time.current, budget: DataQuality::Config.from_env.monthly_budget)
    usage = DataQuality::Budget.usage_this_month(now:)
    Spend.new(calls: usage[:calls], total_tokens: usage[:total_tokens], cost: usage[:cost], budget:)
  end

  def self.run_item(run)
    RunItem.new(id: run.id, source_kind: run.source_kind, stage: run.stage, status: run.status, started_at: run.started_at,
      finished_at: run.finished_at, stats: run.stats.except("llm"), error: run.error, model: run.model)
  end
  private_class_method :run_item
end
