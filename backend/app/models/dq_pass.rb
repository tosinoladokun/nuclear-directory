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
  # Data Quality's dry-run trial of the research (DqPassTrialJob): counted in the daily cap too.
  TRIAL_KIND = "dq_pass_trial".freeze
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

  # When the nightly run starts (config/recurring.yml: 10:30 UTC), in Pacific
  # time as Admin > Health shows times: "2:30 a.m." (3:30 a.m. in summer).
  RUN_AT_UTC = { hour: 10, min: 30 }.freeze
  def self.run_time_pacific(now: Time.current)
    now.utc.change(**RUN_AT_UTC).in_time_zone(PipelineHealth::ZONE).strftime("%-l:%M %P").sub(/ ([ap])m\z/, ' \1.m.')
  end

  # Never recommended for reject by the pass, in code or by a model (Data
  # Quality, 28 Nov): a university, a national lab or a government body (a
  # model reads those), an investor, or a company a person suggested.
  NEVER_REJECT = /\b(?:universit(?:y|ies)|college|institute of technology|national lab(?:oratory)?|laboratory|department of|u\.s\. |agency|administration|authority|commission|capital|ventures|partners|fund)\b/i
  NEVER_REJECT_ROLES = %w[venture_capital university national_lab government_agency].freeze

  def self.never_reject?(org)
    org.name.to_s.match?(NEVER_REJECT) ||
      OrganizationRole.where(organization_id: org.id, role: Role.where(key: NEVER_REJECT_ROLES)).exists? ||
      Lead.where(kind: "company", normalized_name: Lead.normalize(org.name)).any? do |lead|
        lead.sources.any? { |source| source["key"].to_s.match?(DataQuality::Plugins::LeadFinder::PERSON_KEYS) }
      end
  end

  # Model spend today (UTC) by the pass, its trial and the checker together.
  def self.spent_today(now: Time.current)
    CrawlRun.where(source_kind: [ SOURCE_KIND, TRIAL_KIND, DqChecker::SOURCE_KIND ], started_at: now.utc.beginning_of_day..)
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
