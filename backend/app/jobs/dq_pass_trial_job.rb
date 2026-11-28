# Data Quality's trial of the pass's research (#998), before its switch-on:
# the same research on companies Data Quality has already done, as a dry
# run. It proposes and records nothing; each company's answer is kept on the
# trial's CrawlRun for Data Quality to compare with its own (GET
# /api/dq/pass_trials/:token). It runs whether the switch is on or off,
# within the daily cap. It reads pages, which stores them as sources, as any
# fetch does.
#
# The run is made here, as the job runs, inside the pipeline's lock for its
# kind (Copilot): the hourly sweep of abandoned runs never fails a live
# trial, a queued one has no run to sweep, and its spend counts on the day
# it ran.
class DqPassTrialJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dq_pass_trial", duration: 1.hour if respond_to?(:limits_concurrency)
  retry_on DataQuality::Pipeline::AlreadyRunning, wait: 2.minutes, attempts: 5

  # nil: DqPass::Research; tests set a stand-in factory.
  class_attribute :research, default: nil

  def perform(token, organization_ids)
    DataQuality::Pipeline.with_lock(DqPass::TRIAL_KIND) do
      run = CrawlRun.create!(source_kind: DqPass::TRIAL_KIND, stage: "verify", started_at: Time.current,
        stats: { "trial" => token, "organization_ids" => organization_ids })
      run_trial(run, organization_ids)
    end
  end

  private
    def run_trial(run, organization_ids)
      researcher = (research || ->(**opts) { DqPass::Research.new(**opts) }).call(dry_run: true)
      researcher.run = run
      results = Organization.where(id: organization_ids).order(:id).map do |org|
        result = researcher.research(org)
        GC.start # each company's pages freed before the next (#1026)
        answer = result[:answer].to_h
        { "id" => org.id, "name" => org.name, "outcome" => result[:outcome], "model" => answer["model"], "escalated" => answer["escalated"] == true,
          "website" => answer["website"], "website_quote" => answer["website_quote"], "role" => answer["role"], "role_quote" => answer["role_quote"],
          "out_of_scope" => answer["out_of_scope"], "reason" => answer["reason"],
          "would_propose" => result[:proposed].map { |row| row.slice("action", "role", "fields", "verdict") } }
      rescue DqPass::BudgetReached => e
        { "id" => org.id, "name" => org.name, "outcome" => "stopped", "reason" => e.message }
      rescue DataQuality::OpenRouter::Client::Error => e
        { "id" => org.id, "name" => org.name, "outcome" => "error", "reason" => e.message.truncate(200) }
      end
      run.finish!(stats: { "results" => results })
    rescue StandardError => e
      run.fail!(e.message.truncate(200))
      raise
    end
end
