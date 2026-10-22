# The admin's Today page (#373): the day's review as four steps.
#   1 crawl:  last night's crawl, checked by Joy (the app's checker)
#   2 list:   Aminah's (Data Quality's) list, pasted in or skipped
#   3 review: the facts waiting for Accept or Reject
#   4 left:   things that need a visit, not a click (correction requests)
# Steps 1 and 2 are done once the admin marks them (TodayStep). Steps 3 and
# 4 are done when nothing is left in them, or when marked. The current step
# is the first that isn't done. The day is the admin's (Pacific), so it turns
# over at midnight there, which is when the daily crawl starts (3am Eastern).
#
#   today = Today.new
#   today.steps.map { |step| [ step.key, step.state ] } # => [["crawl", :done], ["list", :current], …]
#   today.mark_done!("list", by: "human:tosin", note: "no_list")
class Today
  ZONE = "America/Los_Angeles".freeze
  # A crawl that starts a little before midnight still counts as last night's.
  CRAWL_MARGIN = 1.hour
  # Rough minutes per step: steps 1 and 2 about one each, a fact about ten
  # seconds, a visit about a minute.
  SECONDS_PER_FACT = 10

  Step = Data.define(:key, :number, :state, :count, :minutes, :done_by, :note) do
    def done? = state == :done
    def current? = state == :current
  end
  # One kind of source in last night's crawl. problem: why its latest
  # finished run didn't read it, or nil. running: a run (a retry, say) is
  # still going; a problem stays until a run finishes without one.
  CrawlRow = Data.define(:source_kind, :started_at, :problem, :running) do
    def failed = problem.present?
  end

  def self.date(now = Time.current) = now.in_time_zone(ZONE).to_date

  attr_reader :on

  def initialize(on: Today.date, now: Time.current)
    @on = on
    @now = now
  end

  def steps
    @steps ||= begin
      current = nil
      TodayStep::STEPS.each_with_index.map do |key, index|
        stored = marked[key]
        state = if stored || finished_by_itself?(key) then :done
        elsif current.nil? then current = :current
        else :later
        end
        Step.new(key:, number: index + 1, state:, count: count(key), minutes: minutes(key), done_by: stored&.done_by, note: stored&.note)
      end
    end
  end

  def step(key) = steps.find { |step| step.key == key }
  def current = steps.find(&:current?)
  def done_count = steps.count(&:done?)
  def done? = steps.all?(&:done?)
  def minutes_total = steps.sum(&:minutes)

  # The admin nav's count: facts waiting for a decision, plus step 4's items.
  def nav_count = undecided + left_count

  # Marks a step done (once: marking it again keeps the first).
  def mark_done!(key, by:, note: nil)
    TodayStep.create_or_find_by!(on:, step: key) { |row| row.assign_attributes(done_by: by, note:) }
    reset
  end

  # Undo: the step is open again.
  def undo!(key)
    TodayStep.where(on:, step: key).delete_all
    reset
  end

  # Last night's crawl, one row per kind of source. Its problem comes from
  # the last real outcome of each read its runs made (Today.outcomes), so a
  # same-day rerun that skipped a read ("skipped_recent") neither clears that
  # read's failure nor hides a fresh failure of another read.
  def crawl_rows
    @crawl_rows ||= CrawlRun.where(stage: "crawl", started_at: crawl_window).order(:started_at, :id).to_a
      .group_by(&:source_kind).map do |kind, runs|
        finished = runs.reject { |run| run.status == "running" }
        problem = self.class.problem(finished) || flagged[kind]
        CrawlRow.new(source_kind: kind, started_at: runs.last.started_at, problem:, running: runs.last.status == "running")
      end.sort_by(&:source_kind)
  end

  # A fetch's answers (DataQuality::Snapshot, and plug-ins' own reads): read,
  # skipped as already read today, or not read, with why.
  READ = %w[ok changed unchanged].freeze
  SKIPPED = "skipped_recent".freeze
  FAILED_READS = {
    "blocked" => "a page was blocked", "disallowed" => "robots.txt refused a page",
    "error" => "a page didn't answer", "needs_human" => "a file it couldn't read needs a person"
  }.freeze

  # Why last night's runs of one kind didn't read their source, or nil.
  # Runs are taken in order; each read (a stat such as "list",
  # "status_file", "snapshot", "api" or "site_pages") keeps its last real
  # outcome. A run that failed outright, or that its plug-in stopped
  # ("stopped"), is a problem until a later run reads something cleanly.
  def self.problem(runs)
    outcomes = {}
    halted = nil
    runs.each do |run|
      stats = run.stats.to_h
      fresh = outcomes_of(stats)
      outcomes.merge!(fresh)
      if run.status == "failed" then halted = run.error.presence || "the crawl failed"
      elsif stats["stopped"].present? then halted = stats["stopped"]
      # A run that only skipped reads read nothing, so it clears nothing.
      elsif fresh.any? || !stats.values.include?(SKIPPED) then halted = nil
      end
    end
    halted || outcomes.values.compact.first
  end

  # { read => why it failed, or nil when it read } for the reads a run's
  # stats report this time; skipped reads are left out.
  def self.outcomes_of(stats)
    stats.each_with_object({}) do |(key, value), outcomes|
      case value
      when SKIPPED then next
      when *READ then outcomes[key] = nil
      when *FAILED_READS.keys then outcomes[key] = FAILED_READS.fetch(value)
      when Hash # counts by outcome, e.g. site_pages: { "changed" => 19, "error" => 1 }
        failed = FAILED_READS.keys.find { |outcome| value[outcome].to_i.positive? }
        if failed then outcomes[key] = FAILED_READS.fetch(failed)
        # Counts don't say which pages were skipped: a page that failed
        # earlier may be among them, so only a run that skipped none clears it
        # (#429 records failed pages by id).
        elsif value[SKIPPED].to_i.positive? then next
        elsif (value.keys & READ).any? then outcomes[key] = nil
        end
      else outcomes[key] = "the API answered #{value}" if key == "api"
      end
    end
  end

  def crawl_problems = crawl_rows.count(&:failed)

  # Facts waiting for a decision: everything Checks lists (claims in both
  # queues, and pending facts with no open claim).
  def undecided = @undecided ||= DataQuality::Review.check_counts["all"] + DataQuality::Review.pending_count

  # Step 4: correction requests visitors sent that aren't closed.
  def left_count = @left_count ||= CorrectionReport.where(status: %w[open reviewed]).count

  # Step 4's items, oldest first.
  def left_items = CorrectionReport.where(status: %w[open reviewed]).order(:created_at, :id)

  # When Joy (the verify stage) last finished a run last night, or nil.
  def checker_ran_at
    CrawlRun.where(stage: "verify", status: "succeeded", started_at: crawl_window).maximum(:finished_at)
  end

  # The daily crawl (config/recurring.yml): every day at 3am Eastern.
  def self.next_crawl_at(now = Time.current)
    at = now.in_time_zone("America/New_York").change(hour: 3)
    at > now ? at : at + 1.day
  end

  # This day's decisions: on claims, and a person's direct decisions on facts
  # with no claim behind them (Publish, Add a fact's approval). A claim's own
  # approval records its claim on the fact's event, so it isn't counted twice.
  # How many were approved, were rejected, and were decided by `by`.
  def decisions(by:)
    day = on.in_time_zone(ZONE).all_day
    decided = Candidate.where(reviewed_at: day)
    direct = VerificationEvent.where(created_at: day).where("verification_events.by LIKE 'human:%'")
      .where("verification_events.from_status IS DISTINCT FROM verification_events.to_status")
      .where("NOT (COALESCE(verification_events.context, '{}'::jsonb) ? 'candidate_id')")
    { live: decided.where(status: "merged").count + direct.where(to_status: "verified").count,
      rejected: decided.where(status: "rejected").count + direct.where(to_status: "rejected").count,
      by_you: decided.where(reviewed_by: by).count + direct.where(by:, to_status: %w[verified rejected]).count }
  end

  # Last night's crawl: from 11pm Pacific the evening before to now.
  def crawl_window = window

  private
    def marked = @marked ||= TodayStep.where(on:).index_by(&:step)

    # Kinds with a source the crawl read but flagged as blocked or needing a
    # person (a page whose rows or tables it couldn't use, say), with why:
    # its runs can look clean when the read worked and the check after it didn't.
    def flagged
      @flagged ||= ::Source.where(crawl_status: DataQuality::Status::ATTENTION, fetched_at: crawl_window).order(:id)
        .group_by(&:source_kind).transform_values do |sources|
          source = sources.first
          source.status_reason.presence || (source.crawl_blocked? ? "a page was blocked" : "a page needs a person")
        end
    end


    def finished_by_itself?(key)
      case key
      when "review" then undecided.zero?
      when "left" then left_count.zero?
      else false
      end
    end

    def count(key)
      case key
      when "crawl" then crawl_rows.size
      when "review" then undecided
      when "left" then left_count
      end
    end

    def minutes(key)
      case key
      when "crawl", "list" then 1
      when "review" then (undecided * SECONDS_PER_FACT / 60.0).ceil
      when "left" then left_count
      end
    end

    def window
      start = on.in_time_zone(ZONE).beginning_of_day - CRAWL_MARGIN
      start..[ start + 1.day + CRAWL_MARGIN, @now ].min
    end

    # Everything read from the database: marking or undoing a step reads it all again.
    def reset
      @steps = @marked = @undecided = @left_count = @crawl_rows = @flagged = nil
    end
end
