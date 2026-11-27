# Data Quality's trial of the pass's research (#998), before its switch-on:
# the same research on companies Data Quality has already done, as a dry
# run. It proposes and records nothing; each company's answer is kept on the
# trial's CrawlRun for Data Quality to compare with its own (GET
# /api/dq/pass_trials/:id). It runs whether the switch is on or off, within
# the daily cap. It reads pages, which stores them as sources, as any fetch does.
class DqPassTrialJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dq_pass_trial", duration: 1.hour if respond_to?(:limits_concurrency)

  # nil: DqPass::Research; tests set a stand-in factory.
  class_attribute :research, default: nil

  def perform(run_id, organization_ids)
    run = CrawlRun.find(run_id)
    researcher = (research || ->(**opts) { DqPass::Research.new(**opts) }).call(dry_run: true)
    researcher.run = run
    results = Organization.where(id: organization_ids).order(:id).map do |org|
      result = researcher.research(org)
      answer = result[:answer].to_h
      { "id" => org.id, "name" => org.name, "outcome" => result[:outcome], "model" => answer["model"], "escalated" => answer["escalated"] == true,
        "website" => answer["website"], "website_quote" => answer["website_quote"], "role" => answer["role"], "role_quote" => answer["role_quote"],
        "out_of_scope" => answer["out_of_scope"], "reason" => answer["reason"],
        "would_propose" => result[:proposed].map { |row| row.slice("action", "role", "fields", "verdict") } }
    rescue DqPass::BudgetReached => e
      { "id" => org.id, "name" => org.name, "outcome" => "stopped", "reason" => e.message }
    end
    run.finish!(stats: { "results" => results })
  rescue StandardError => e
    run&.fail!(e.message.truncate(200))
    raise
  end
end
