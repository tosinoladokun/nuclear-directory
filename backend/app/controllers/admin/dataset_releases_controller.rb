# The monthly open dataset release (#950): the draft Data Quality checks,
# Rebuild after a fix, a dry run of publishing, and Publish (Tosin, after
# Data Quality's OK). Building and publishing run as jobs; a dry run only
# reads the data repo, so it runs here.
class Admin::DatasetReleasesController < Admin::BaseController
  def show
    @releases = DatasetRelease.newest_first.limit(36).to_a
    @release = @releases.find { |release| !release.published? }
    @published = @releases.select(&:published?)
    @this_month = Date.current.strftime("%Y.%m")
    @set_up = DatasetRelease.publishing_set_up?
    @tables = DatasetRelease.tables_setting
  end

  def build
    version = params[:version].to_s.presence || Date.current.strftime("%Y.%m")
    return redirect_to(admin_dataset_releases_path, alert: "That isn't a version.") unless version.match?(/\A\d{4}\.\d{2}\z/)

    release = DatasetRelease.find_by(version:)
    if release && !release.rebuildable?
      return redirect_to(admin_dataset_releases_path, alert: "v#{version} can't be rebuilt: #{release.published? ? "it's published" : "publishing it has started"}.")
    end

    DatasetBuildDraftJob.perform_later(version)
    redirect_to admin_dataset_releases_path, notice: "Building v#{version}. It takes about a minute; refresh to see it."
  end

  def dry_run
    release = DatasetRelease.find(params[:id])
    Dataset::Publisher.new(release).dry_run
    redirect_to admin_dataset_releases_path(anchor: "dry-run"), notice: "Dry run done. Nothing was sent to GitHub."
  rescue Dataset::Github::Error => e
    redirect_to admin_dataset_releases_path, alert: "Dry run failed: #{e.message}"
  end

  def publish
    release = DatasetRelease.find(params[:id])
    refused = if !DatasetRelease.publishing_set_up? then "Publishing isn't set up yet."
    elsif !release.publishable? then "v#{release.version} can't be published: #{release.published? ? "it's published already" : "it has no files"}."
    end
    return redirect_to(admin_dataset_releases_path, alert: refused) if refused

    DatasetPublishJob.perform_later(release.id)
    redirect_to admin_dataset_releases_path, notice: "Publishing v#{release.version}. It takes about a minute; refresh to see the release link."
  end
end
