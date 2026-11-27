# Data Quality's daily pass on the server (#998): the routine work Data
# Quality's local session did by hand, run each night with no laptop. It
# only recommends and proposes; Tosin still decides new companies and facts.
#
# - Off until a person switches it on (Admin > Health, Switch "dq_pass"), so
#   the first live night is deliberate. The shadow checker (DqChecker) runs
#   either way, as before.
# - One daily cap, DAILY_BUDGET dollars, for the pass and the checker
#   together, counted from crawl_runs (never a cache). Over it, a step stops
#   and what's left waits for a person or the next night.
# - Steps run in order. Each takes the run and returns its counts; it checks
#   DqPass.budget_left? before every model call.
module DqPass
  KEY = "dq_pass".freeze
  SOURCE_KIND = "dq_pass".freeze
  DAILY_BUDGET = 1.0
  # Autopilot alert keys (Autopilot::Owners).
  FAILED = "dq-pass-failed".freeze
  STALLED = "dq-pass-stalled".freeze
  BUDGET = "dq-pass-budget".freeze
  # A run that hasn't succeeded for this long, while the switch is on, is stalled.
  STALE_AFTER = 26.hours

  # Raised by a step when the day's cap is reached.
  class BudgetReached < StandardError; end

  def self.on? = Switch.on?(KEY)

  # Model spend today (UTC) by the pass and the checker together.
  def self.spent_today(now: Time.current)
    CrawlRun.where(source_kind: [ SOURCE_KIND, DqChecker::SOURCE_KIND ], started_at: now.utc.beginning_of_day..)
      .sum("COALESCE((stats->'llm'->>'cost')::numeric, 0)").to_f
  end

  def self.budget_left?(now: Time.current) = spent_today(now:) < DAILY_BUDGET

  # Raises BudgetReached when the day's cap is used: call it before every model call.
  def self.check_budget!(now: Time.current)
    raise BudgetReached, "the day's $#{format('%.2f', DAILY_BUDGET)} for Data Quality's pass is used" unless budget_left?(now:)
  end

  # Why the pass looks stalled, or nil: the switch is on and no run has
  # succeeded within STALE_AFTER of now (counted from the switch-on when it's
  # newer than the last success).
  def self.stalled(now: Time.current)
    switch = Switch.find_by(key: KEY, on: true) or return
    last = CrawlRun.where(source_kind: SOURCE_KIND, status: "succeeded").maximum(:finished_at)
    since = [ last, switch.updated_at ].compact.max
    return if since > now - STALE_AFTER

    last ? "Data Quality's pass hasn't finished a run since #{last.in_time_zone(PipelineHealth::ZONE).strftime('%-d %b %H:%M')}" :
      "Data Quality's pass is on but hasn't finished a run"
  end
end
