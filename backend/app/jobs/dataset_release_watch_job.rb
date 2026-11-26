# Every hour (config/recurring.yml, #950). It does two things:
#
# - It finds each published dataset release's version DOI on Zenodo once
#   doi.org resolves it, and saves it on the release. If none appears within
#   DOI_WAIT of publishing, an alert says so.
# - From the 7th of a month, if that month's release isn't published, an alert
#   says so, so the release never depends on someone remembering.
#
# Each alert is resolved once its cause clears. The job reads Zenodo and the
# release rows, and writes only version_doi.
class DatasetReleaseWatchJob < ApplicationJob
  queue_as :default

  LATE = "dataset-release-late".freeze
  NO_DOI = "dataset-doi".freeze
  DUE_BY_DAY = 7
  DOI_WAIT = 2.hours

  # nil: Autopilot::Alert and Dataset::Zenodo; tests set stand-ins.
  class_attribute :alerts, default: nil
  class_attribute :zenodo, default: nil

  def perform(now: Time.current)
    find_dois(now)
    check_due(now)
  end

  private
    def helper = alerts || Autopilot::Alert

    def find_dois(now)
      waiting = DatasetRelease.where(status: "published", version_doi: [ nil, "" ]).order(:version).to_a
      return helper.resolve!(NO_DOI, note: "Every published dataset release has its version DOI.") if waiting.empty?

      client = zenodo || Dataset::Zenodo.new
      missing = waiting.reject do |release|
        doi = client.version_doi(release.version)
        release.update!(version_doi: doi) if doi
        doi
      rescue Dataset::Zenodo::Error => e
        Rails.logger.warn("[dataset] Zenodo check for v#{release.version}: #{e.message}")
        false
      end
      overdue = missing.select { |release| release.published_at && release.published_at < now - DOI_WAIT }
      if overdue.any?
        helper.raise!(NO_DOI, title: "No Zenodo DOI for dataset #{overdue.map(&:tag).join(', ')}",
          body: overdue.map { |release| "#{release.tag} was published #{release.published_at.utc.strftime('%-d %b %H:%M UTC')} (#{release.release_url}). " \
            "Zenodo hasn't shown a version DOI that resolves." }.join("\n") +
            "\n\nCheck the Zenodo webhook on the data repo, and the upload's status on Zenodo.")
      else
        # A newer release still inside its wait doesn't keep an older one's alert open (Copilot).
        helper.resolve!(NO_DOI, note: "No published dataset release is overdue for its version DOI.")
      end
    end

    def check_due(now)
      day = now.in_time_zone.to_date
      version = day.strftime("%Y.%m")
      release = DatasetRelease.find_by(version:)
      # v2026.11 and before were published by hand, without a row (Copilot).
      published = release&.published? || version <= StructuredDataHelper::FIRST_RELEASE
      return helper.resolve!(LATE, note: "Dataset v#{version} is published.") if published
      return if day.day < DUE_BY_DAY

      state = if release.nil? then "No draft has been built."
      elsif release.failed? then "Publishing failed: #{release.error.to_s.truncate(200)}"
      else "The draft is waiting for Data Quality's OK and Publish."
      end
      helper.raise!(LATE, title: "Dataset v#{version} isn't published yet", body: "#{state}\n\nSee Admin > Dataset releases.")
    end
end
