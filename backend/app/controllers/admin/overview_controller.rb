# The admin's home (#201): today's date, a tile per stage with its count,
# and the pipeline's
# health, folded: what needs attention, the last run per stage, model spend
# and visitors on PostHog (the admin's view of data_quality:status).
class Admin::OverviewController < Admin::BaseController
  def show
    @attention = DataQuality::Status.sources
    @runs = DataQuality::Status.runs
    @spend = DataQuality::Status.spend
    @analytics_url = ENV["POSTHOG_DASHBOARD_URL"].presence
  end
end
