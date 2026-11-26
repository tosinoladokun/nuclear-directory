# Publishes a dataset release (#950), after Tosin's Publish on the admin page.
# The publisher records a failure on the release; publishing again resumes.
class DatasetPublishJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dataset_release", duration: 30.minutes if respond_to?(:limits_concurrency)

  def perform(release_id, built_at = nil)
    Dataset::Publisher.new(DatasetRelease.find(release_id)).publish!(built_at:)
  rescue Dataset::Publisher::AlreadyPublished => e
    Rails.logger.info("Dataset release #{release_id}: #{e.message}")
  rescue Dataset::Publisher::Refused, Dataset::Github::Error => e
    Rails.logger.warn("Dataset release #{release_id} not published: #{e.message}")
    Sentry.capture_message("Dataset release not published: #{e.message}", level: :error) if defined?(Sentry) && Sentry.initialized?
  end
end
