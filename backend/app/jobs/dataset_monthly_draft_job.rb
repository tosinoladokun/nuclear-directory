# On the 1st of each month (config/recurring.yml, #950): builds this month's
# dataset release draft from production, then emails the team inbox that it's
# ready for Data Quality's check on Admin > Dataset releases. If the build
# fails, an alert says so (Sentry and email) until a later build works.
#
# Counts and the version go in the email; never file contents or a token.
class DatasetMonthlyDraftJob < ApplicationJob
  queue_as :default
  limits_concurrency to: 1, key: "dataset_release", duration: 30.minutes if respond_to?(:limits_concurrency)

  READY = "dataset-draft-ready".freeze
  FAILED = "dataset-draft-failed".freeze

  # nil: Autopilot::Alert and AutopilotMailer; tests set stand-ins.
  class_attribute :alerts, default: nil
  class_attribute :mailer, default: nil

  def perform(version = Date.current.strftime("%Y.%m"))
    release = Dataset::Draft.build!(version:)
  rescue Dataset::Draft::Refused => e
    Rails.logger.info("[dataset] monthly draft v#{version} not built: #{e.message}")
  rescue StandardError => e
    (alerts || Autopilot::Alert).raise!(FAILED, title: "The dataset draft v#{version} couldn't be built",
      body: "#{e.class.name}: #{e.message.to_s.truncate(300)}\n\nTry Rebuild on Admin > Dataset releases once it's fixed.")
    raise
  else
    (alerts || Autopilot::Alert).resolve!(FAILED, note: "The dataset draft v#{version} was built.")
    (mailer || AutopilotMailer).notify(key: READY, title: "Dataset v#{version} is ready for Data Quality's check",
      body: self.class.ready_body(release), state: :raised)
  end

  def self.ready_body(release)
    counts = release.ordered_counts.map do |table, count|
      was = release.previous_counts&.[](table)
      "#{table}: #{count}#{" (#{format('%+d', count - was)} since #{release.previous_version})" if was}"
    end
    held = Dataset::Export::TABLES.keys - release.tables_included
    [ "The draft of v#{release.version} is built from production.", "", *counts,
      ("Held back: #{held.join(', ')}." if held.any?),
      ("Publishers without a name: #{release.unknown_publishers.size}." if release.unknown_publishers.any?), "",
      "Data Quality: check the counts on Admin > Dataset releases and give the OK. Then Tosin publishes it there." ].compact.join("\n")
  end
end
