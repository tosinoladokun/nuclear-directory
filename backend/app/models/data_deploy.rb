# One run of the deploy's data step (#301, bin/deploy-data) that wrote, or
# tried to. applied: the seed and data migrations ran; the next run compares
# its files with this one's. reported: report mode ran them and rolled back,
# for the steps done by hand (report holds the migrations it covered).
# stopped: a check stopped it before any write (collision, backup, crawl
# running). failed: an error; nothing from the failed step was written.
class DataDeploy < ApplicationRecord
  enum :status, %w[applied reported stopped failed].index_by(&:itself), validate: true

  # The run the next one compares with: in report mode the last reported or
  # applied run, otherwise the last applied one.
  def self.baseline(report_mode:) = where(status: report_mode ? %w[applied reported] : %w[applied]).order(:id).last

  # Data migrations report mode has already reported, so it doesn't repeat them.
  def self.reported_migrations = reported.pluck(:report).flat_map { |report| Array(report["migrations"]) }.to_set
end
