# Daily (config/recurring.yml): the pipeline's health is kept, and each problem goes to Sentry so a person hears of
# it (#811). Infra wires the alert from there.
class PipelineHealthJob < ApplicationJob
  queue_as :default

  class Stalled < StandardError; end

  def perform
    row = PipelineHealth.new.record!
    row.problems.each do |problem|
      Rails.error.report(Stalled.new(problem), handled: true, severity: :warning, context: { pipeline_health: row.counts })
    end
  end
end
