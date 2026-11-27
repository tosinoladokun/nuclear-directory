require "test_helper"

# #1018: a data step runs in Render's pre-deploy, while the old release's worker still runs, so a job it queues at
# once runs on the old code. Every job a step queues waits past the release switch.
class DeployData::QueueAfterDeployTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  STEPS = Dir[Rails.root.join("db/data/*.rb")].freeze

  test "no data step queues a job at once" do
    offenders = STEPS.flat_map do |file|
      File.readlines(file).each_with_index.filter_map do |line, i|
        next if line.strip.start_with?("#")

        at_once = line.match?(/\.perform_later\b/) || (line.include?("CompanySuggestion.queue(") && !line.include?("wait:"))
        "#{File.basename(file)}:#{i + 1}" if at_once
      end
    end
    assert_empty offenders, "queue jobs with queue_after_deploy or wait: AFTER_DEPLOY_WAIT (#1018)"
  end

  test "queue_after_deploy schedules the job past the release switch" do
    step = DeployData::Migration.new(reason: "deploy abc1234, PR #1")
    freeze_time do
      assert_enqueued_with(job: LeadFindJob, args: [ 42 ], at: DeployData::Migration::AFTER_DEPLOY_WAIT.from_now) do
        step.queue_after_deploy(LeadFindJob, 42)
      end
    end
  end

  test "a re-queued lead from a data step is found after the wait, a suggestion at once" do
    lead = Lead.sighted!(name: "Acme Fission", kind: "company", key: "nea:1", label: "NEA list")
    freeze_time do
      assert_enqueued_with(job: LeadFindJob, args: [ lead.id ], at: DeployData::Migration::AFTER_DEPLOY_WAIT.from_now) do
        CompanySuggestion.queue(lead, name: "Acme Fission", by: "human:tosin", wait: DeployData::Migration::AFTER_DEPLOY_WAIT)
      end
    end
    clear_enqueued_jobs
    lead.update!(note: nil)
    assert_enqueued_with(job: LeadFindJob, args: [ lead.id ], at: nil) do
      CompanySuggestion.queue(lead, name: "Acme Fission", by: "human:tosin")
    end
  end
end
