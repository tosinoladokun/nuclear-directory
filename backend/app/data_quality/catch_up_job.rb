# Hourly, in production (config/recurring.yml). When the instance restarts
# mid-run (#188: it ran out of memory during the EIA crawl), the run is left
# "running" and Solid Queue drops the job without retrying it. This job:
# - marks runs left "running" by a process that died as failed, without
#   waiting for that source's next run (Pipeline.sweep_all_abandoned)
# - queues today's daily crawl again, from the first source the daily job
#   started but never finished (cut off), or never started by CATCH_UP_AFTER
#
# Each source is caught up at most once a day, so a source that keeps
# killing the instance waits for a person instead of looping. Fetching is
# still once a day per source (Snapshot), so a catch-up re-uses what was
# already fetched today.
class DataQuality::CatchUpJob < ApplicationJob
  ZONE = "America/New_York"
  # An hour after config/recurring.yml's daily_crawl (3am), so it has started.
  CATCH_UP_AFTER = 4
  # Holds the daily marks below. The app's cache is
  # database-backed in production (Solid Cache), so it survives the restart
  # that caused the catch-up; tests use their own, since the test cache
  # keeps nothing.
  CACHE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  queue_as :data_quality
  limits_concurrency to: 1, key: "data_quality_catch_up"

  def perform(now: Time.current)
    DataQuality::Pipeline.sweep_all_abandoned
    # Claims a crawl attached mid-merge, if match didn't catch them (#325).
    DataQuality::DirectoryClient.new.repoint_merged_claims

    local = now.in_time_zone(ZONE)
    return if local.hour < CATCH_UP_AFTER

    date = local.to_date
    kinds = DataQuality::DailyCrawlJob::SOURCE_KINDS
    # After the sweep, a run still "running" really is (its lock is held):
    # wait for it, so EIA is never queued while NRC is still going.
    return if CrawlRun.running.exists?(source_kind: kinds)

    first = kinds.index { |kind| needs_catching_up?(kind, date) }
    return unless first

    behind = kinds.drop(first)
    # Queued first, then remembered: if queueing fails, the next hour tries again.
    DataQuality::DailyCrawlJob.perform_later(behind)
    behind.each { |kind| mark(:caught_up, kind, date) }
  end

  # DailyCrawlJob records when it starts and finishes each source today.
  # A source started but never finished was cut off; one never started
  # missed the daily crawl. Runs started by hand (data_quality:stage,
  # :rerun) leave no marks, so they're never mistaken for either.
  def self.daily_started!(kind, now: Time.current) = mark(:started, kind, today(now))
  def self.daily_finished!(kind, now: Time.current) = mark(:finished, kind, today(now))
  def self.daily_not_started!(kind, now: Time.current) = CACHE.delete(key(:started, kind, today(now)))

  def self.today(now) = now.in_time_zone(ZONE).to_date
  def self.mark(state, kind, date) = CACHE.write(key(state, kind, date), true, expires_in: 2.days)
  def self.marked?(state, kind, date) = CACHE.exist?(key(state, kind, date))
  def self.key(state, kind, date) = "data_quality:daily:#{state}:#{kind}:#{date.iso8601}"

  private
    # Done today when it finished, whether it succeeded or stopped on an
    # ordinary failure (a refused key, a blocked page), which waits for a
    # person. Behind when it started and never finished, or never started.
    def needs_catching_up?(kind, date) = !marked?(:caught_up, kind, date) && !marked?(:finished, kind, date)

    def mark(...) = self.class.mark(...)
    def marked?(...) = self.class.marked?(...)
end
