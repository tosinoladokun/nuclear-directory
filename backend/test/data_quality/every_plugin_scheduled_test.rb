require "test_helper"

# A reader merged but never scheduled runs nowhere (EIA-860 #781, eia_owners
# #822). Every plug-in is on the nightly list, on a recurring job, or in
# DailyCrawlJob::NOT_SCHEDULED with its reason.
class DataQuality::EveryPluginScheduledTest < ActiveSupport::TestCase
  test "every plug-in is scheduled, or marked not scheduled with a reason" do
    plugins = Dir[Rails.root.join("app/data_quality/plugins/*.rb")].map { |path| File.basename(path, ".rb") }
    recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).values.flat_map do |jobs|
      Array(jobs.is_a?(Hash) ? jobs.values : jobs).flat_map { |job| job.is_a?(Hash) ? Array(job["args"]).flatten.map(&:to_s) : [] }
    end
    scheduled = DataQuality::DailyCrawlJob::SOURCE_KINDS + recurring + DataQuality::DailyCrawlJob::NOT_SCHEDULED.keys
    missing = plugins - scheduled
    assert_empty missing, "never run: add to DailyCrawlJob::SOURCE_KINDS or config/recurring.yml, or to NOT_SCHEDULED with a reason"
    assert DataQuality::DailyCrawlJob::NOT_SCHEDULED.values.all?(&:present?)
  end
end
