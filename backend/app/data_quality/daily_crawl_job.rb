# The daily crawl (#53), queued by config/recurring.yml in production: the
# whole pipeline for each source, one after the other, so EIA (which
# enriches NRC's units) always starts after NRC has finished. A source that
# fails doesn't stop the next one; the first error is raised at the end so
# the job shows as failed and reaches Sentry. USAspending's DOE awards
# (#260) run last: they don't depend on the others, and a slow API there
# can't hold up NRC and EIA.
#
# If a source is already being run (from the console, say), the job queues
# itself again for that source and the ones after it, so a retry never
# repeats a source that already ran, and still fails for any that failed.
# Each source gets its own ATTEMPTS.
class DataQuality::DailyCrawlJob < ApplicationJob
  SOURCE_KINDS = %w[nrc_reactor_list eia_generators usaspending_doe_awards nrc_decommissioning doe_isotope_sites nrc_uranium_recovery company_newsrooms nrc_reactor_vendors nrc_fuel_cycle nrc_research_reactors doe_programs federal_register_nrc trade_press sec_form_d doe_nuclear_news].freeze
  RETRY_WAIT = 10.minutes
  ATTEMPTS = 30

  queue_as :data_quality
  limits_concurrency to: 1, key: "daily_crawl", duration: 6.hours

  def perform(source_kinds = SOURCE_KINDS, attempt: 1)
    errors = []
    source_kinds.each_with_index do |source_kind, index|
      # Marked so the hourly CatchUpJob can tell a source cut off by a
      # restart (started, never finished) from one that ran.
      DataQuality::CatchUpJob.daily_started!(source_kind)
      DataQuality::Pipeline.run(source_kind)
      DataQuality::CatchUpJob.daily_finished!(source_kind)
    rescue DataQuality::Pipeline::AlreadyRunning
      DataQuality::CatchUpJob.daily_not_started!(source_kind)
      # `attempt` counts tries at the first source in the list; a source
      # reached later in this run has had only this one.
      tries = index.zero? ? attempt : 1
      raise if tries >= ATTEMPTS
      self.class.set(wait: RETRY_WAIT).perform_later(source_kinds.drop(index), attempt: tries + 1)
      break
    rescue StandardError => error
      # Finished, though failed: an ordinary failure waits for a person.
      DataQuality::CatchUpJob.daily_finished!(source_kind)
      errors << error
    end
    raise errors.first if errors.any?
  end
end
