# Queued nightly by config/recurring.yml (#510), after the daily crawl.
class DataQuality::LinkCheckJob < ApplicationJob
  queue_as :data_quality
  limits_concurrency to: 1, key: "link_check", duration: 2.hours

  def perform
    stats = DataQuality::LinkCheck.new.run
    Rails.logger.info("[link_check] #{stats.transform_values { |value| value.is_a?(Array) ? value.size : value }.to_json}")
    stats
  end
end
