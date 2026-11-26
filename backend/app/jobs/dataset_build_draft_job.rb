# Builds (or rebuilds) a dataset release draft (#950): Rebuild on the admin
# page, and on the 1st of each month (Infra's recurring entry). A refusal
# (published, or publishing started) is logged and recorded, not retried.
class DatasetBuildDraftJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dataset_release", group: "dataset_release", duration: 30.minutes if respond_to?(:limits_concurrency)

  # nil: Autopilot::Alert; tests set a stand-in.
  class_attribute :alerts, default: nil

  def perform(version = Date.current.strftime("%Y.%m"))
    Dataset::Draft.build!(version:)
  rescue Dataset::Draft::Refused => e
    Rails.logger.info("Dataset draft v#{version} not built: #{e.message}")
  rescue Dataset::Github::Error, Dataset::Draft::MissingInput => e
    DatasetRelease.find_by(version:)&.update!(error: "Couldn't build: #{e.message}")
    raise
  else
    # A Rebuild after a failed monthly build clears its alert (Copilot, #952).
    (alerts || Autopilot::Alert).resolve!(DatasetMonthlyDraftJob::FAILED, note: "The dataset draft v#{version} was rebuilt.")
  end
end
