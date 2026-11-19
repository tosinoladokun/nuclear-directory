# Daily (config/recurring.yml): the pipeline's health is kept; its problems go out in one email to hello@ (PM), each
# to Sentry, and each to Infra's Autopilot::Alert (one open GitHub issue per stalled stage, closed when it's fine
# again). Once a day, so at most one email per stalled stage per day (#811). Texts are counts only: the repo is public.
class PipelineHealthJob < ApplicationJob
  queue_as :default

  class Stalled < StandardError; end

  def perform
    health = PipelineHealth.new
    row = health.record!
    HealthMailer.notify(row.problems)
    health.checks.each do |key, problem|
      if problem
        Rails.error.report(Stalled.new(problem), handled: true, severity: :warning, context: { pipeline_health: key })
        alert(:raise!, key, title: problem.upcase_first.truncate(120), body: "#{problem.upcase_first}.\n\nSee Admin > Health.")
      else
        alert(:resolve!, key, note: "Back to normal.")
      end
    end
  end

  private
    # Until Infra's helper ships, nothing more than the email and Sentry.
    def alert(action, key, **options)
      Autopilot::Alert.public_send(action, key, **options) if defined?(Autopilot::Alert)
    end
end
