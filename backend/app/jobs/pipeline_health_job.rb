# Daily (config/recurring.yml): the pipeline's health is kept, and each stalled stage goes to Infra's Autopilot::Alert
# (#815: one email to hello@ and a Sentry error per stage, again only after 20 h; "back to normal" when it clears).
# Until that ships, the day's problems go in one email and to Sentry from here. Texts are counts only (#811).
class PipelineHealthJob < ApplicationJob
  queue_as :default

  class Stalled < StandardError; end

  def perform
    health = PipelineHealth.new
    row = health.record!
    return fallback(row.problems) unless defined?(Autopilot::Alert)

    health.checks.each do |key, problem|
      if problem
        Autopilot::Alert.raise!(key, title: problem.upcase_first.truncate(120), body: "#{problem.upcase_first}.\n\nSee Admin > Health.")
      else
        Autopilot::Alert.resolve!(key, note: "Back to normal.")
      end
    end
  end

  private
    def fallback(problems)
      HealthMailer.notify(problems)
      # Captured directly: Rails.error.report doesn't reach Sentry here (its error subscriber is off; Copilot).
      problems.each { |problem| Sentry.capture_message("Pipeline: #{problem}", level: :warning) if defined?(Sentry) && Sentry.initialized? }
    end
end
