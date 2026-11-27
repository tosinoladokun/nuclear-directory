# Data Quality's daily pass (#998), each night after the shadow checker.
# Does nothing while its switch is off. A failed run raises an Autopilot
# alert (email, Sentry, Admin > Health) until a run succeeds; a run stopped
# by the daily cap raises its own. Never in a web request.
class DqPassJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dq_pass", duration: 2.hours if respond_to?(:limits_concurrency)

  # The pass's steps, in order. Each responds to call(run) and returns a
  # counts Hash. nil: STEPS. Tests set stand-ins.
  STEPS = [].freeze
  class_attribute :steps, default: nil
  # nil: Autopilot::Alert; tests set a stand-in.
  class_attribute :alerts, default: nil

  def perform(now: Time.current)
    return { "skipped" => "switched off" } unless DqPass.on?

    run = CrawlRun.create!(source_kind: DqPass::SOURCE_KIND, stage: "verify", started_at: now)
    counts = {}
    begin
      (steps || STEPS).each do |step|
        counts.merge!(step.call(run).to_h) { |_key, was, more| was.to_i + more.to_i }
      end
    rescue DqPass::BudgetReached => e
      counts["stopped_for_budget"] = 1
      helper.raise!(DqPass::BUDGET, title: "Data Quality's pass stopped at its daily cap",
        body: "#{e.message.upcase_first}. What's left waits for tomorrow's run or a person.\n\nSee Admin > Health.")
    end
    run.finish!(stats: counts)
    helper.resolve!(DqPass::FAILED, note: "Data Quality's pass finished a run.")
    helper.resolve!(DqPass::BUDGET, note: "Data Quality's pass finished within its daily cap.") unless counts["stopped_for_budget"]
    counts
  rescue StandardError => e
    run&.fail!(e.message.truncate(200))
    helper.raise!(DqPass::FAILED, title: "Data Quality's pass failed",
      body: "#{e.class.name}: #{e.message.to_s.truncate(300)}\n\nIt tries again tomorrow night. See Admin > Health.")
    raise
  end

  private
    def helper = alerts || Autopilot::Alert
end
