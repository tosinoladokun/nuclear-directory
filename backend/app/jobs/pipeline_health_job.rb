# Daily (config/recurring.yml): the pipeline's health is kept; its problems go out in one email to hello@ (PM) and
# each to Sentry (#811). Once a day, so at most one email per stalled stage per day.
class PipelineHealthJob < ApplicationJob
  queue_as :default

  class Stalled < StandardError; end

  def perform
    row = PipelineHealth.new.record!
    HealthMailer.notify(row.problems)
    row.problems.each do |problem|
      Rails.error.report(Stalled.new(problem), handled: true, severity: :warning, context: { pipeline_health: row.counts })
    end
  end
end
