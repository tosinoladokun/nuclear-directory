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

  # Last night's crawl, one row per kind of source, judged by its latest
  # finished run.
  def crawl_rows
    @crawl_rows ||= CrawlRun.where(stage: "crawl", started_at: crawl_window).order(:started_at, :id).to_a
      .group_by(&:source_kind).map do |kind, runs|
        finished = runs.reject { |run| run.status == "running" }.last
        CrawlRow.new(source_kind: kind, started_at: runs.last.started_at, problem: (problem(finished) if finished),
          running: runs.last.status == "running")
      end.sort_by(&:source_kind)
  end

  # Why a finished crawl run didn't read its source, or nil. A run can
  # succeed while its plug-in stopped on a blocked page ("stopped"), left a
  # file for a person ("needs_human") or got no answer from an API ("api").
  def self.problem(run)
    stats = run.stats.to_h
    if run.status == "failed" then run.error.presence || "the crawl failed"
    elsif stats["stopped"].present? then stats["stopped"]
    elsif stats.values.include?("needs_human") then "a file it couldn't read needs a person"
    elsif stats.values.include?("blocked") then "a page was blocked"
    elsif stats.key?("api") && !%w[ok skipped_recent].include?(stats["api"]) then "the API answered #{stats['api']}"
    end
  end

  def crawl_problems = crawl_rows.count(&:failed)

  # Facts waiting for a decision: everything Checks lists (claims in both
  # queues, and pending facts with no open claim).
  def undecided = @undecided ||= DataQuality::Review.check_counts["all"] + DataQuality::Review.pending_count

  # Step 4: correction requests visitors sent that aren't closed.
  def left_count = @left_count ||= CorrectionReport.where(status: %w[open reviewed]).count

  private
    def marked = @marked ||= TodayStep.where(on:).index_by(&:step)

    def problem(run) = self.class.problem(run)

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

    def crawl_window
      start = on.in_time_zone(ZONE).beginning_of_day - CRAWL_MARGIN
      start..[ start + 1.day + CRAWL_MARGIN, @now ].min
    end

    # Everything read from the database: marking or undoing a step reads it all again.
    def reset
      @steps = @marked = @undecided = @left_count = @crawl_rows = nil
    end
end
