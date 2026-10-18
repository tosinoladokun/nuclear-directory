# What model calls have cost this calendar month, from the cost OpenRouter
# reports on each call. The client checks it before every call and refuses
# once the budget is used up, so a runaway run fails with a clear reason
# instead of on a provider error mid-run.
#
# Usage is counted by the month each call was made
# (crawl_runs.stats["llm"]["by_month"]), so a run that crosses midnight at
# month end is split correctly. Runs recorded before that existed count by
# the month they started.
#
# It's a soft limit: calls already in flight when the budget runs out (one
# per concurrently running source kind, a fraction of a cent each) still
# complete, so spend can pass the budget by that much. Serializing every
# model call app-wide to close that gap isn't worth it; the OpenRouter key's
# own credit limit is the hard stop.
module DataQuality::Budget
  class Exceeded < StandardError; end

  # Calls, tokens and US dollars for model calls made this calendar month.
  def self.usage_this_month(now: Time.current)
    start = now.beginning_of_month
    finish = start.next_month
    key = start.strftime("%Y-%m")
    # Every run: one started long ago can still be making calls this month
    # (the abandoned-run sweep doesn't stop a run that's really working).
    # by_month picks out this month's share; older runs without it count by
    # start month, bounded above too so a historical now: (#95) doesn't pull
    # in legacy rows from later months. The table is small, one row per stage run.
    runs = CrawlRun.all
    month = ->(field, cast) do
      "COALESCE(SUM(CASE WHEN stats -> 'llm' -> 'by_month' IS NOT NULL " \
        "THEN (stats -> 'llm' -> 'by_month' -> #{CrawlRun.connection.quote(key)} ->> '#{field}')::#{cast} " \
        "WHEN started_at >= #{CrawlRun.connection.quote(start)} AND started_at < #{CrawlRun.connection.quote(finish)} " \
        "THEN (stats -> 'llm' ->> '#{field}')::#{cast} END), 0)"
    end
    calls, tokens, cost = runs.pick(Arel.sql(month.("calls", "int")), Arel.sql(month.("total_tokens", "int")),
      Arel.sql(month.("cost", "numeric")))
    { calls: calls.to_i, total_tokens: tokens.to_i, cost: cost.to_f }
  end

  # US dollars spent on model calls this calendar month.
  def self.spent_this_month(now: Time.current) = usage_this_month(now:)[:cost]

  def self.check!(budget)
    spent = spent_this_month
    return if spent < budget

    raise Exceeded, format("Monthly model budget of $%.2f is used up ($%.4f spent since %s). " \
      "Raise DATA_QUALITY_MONTHLY_BUDGET or wait until next month.", budget, spent, Time.current.beginning_of_month.to_date)
  end
end
