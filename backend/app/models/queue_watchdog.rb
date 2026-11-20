# Keeps the job queue alive (PM, P0 after 19 Nov). Runs as a thread in the web process (started from
# config/puma.rb when Solid Queue runs inside Puma), once a minute, outside the queue:
#
# - The queue stuck (QueueHealth): an alert ("queue-stuck") by email, sent now rather than through the stuck
#   queue, and to Sentry; resolved once it works again.
# - This process's own worker gone quiet for RESTART_AFTER while the database answers (a crash killed its
#   thread): the process stops itself (TERM, Puma's graceful stop) so Render starts a fresh one.
#
# While the database is down nothing is decided: a blip is waited out, never answered with a restart.
class QueueWatchdog
  EVERY = 60
  RESTART_AFTER = 5.minutes
  # A fresh process has no heartbeat yet.
  GRACE = 5.minutes
  KEY = "queue-stuck".freeze

  class_attribute :stopper, default: -> { ::Process.kill("TERM", ::Process.pid) }

  def self.start
    return if @thread&.alive?

    booted = Time.current
    @thread = Thread.new do
      loop do
        sleep EVERY
        Rails.application.executor.wrap { new(booted:).tick }
      rescue StandardError => error
        Rails.logger.error("[queue_watchdog] #{error.class}: #{error.message}")
      end
    end
  end

  def initialize(booted:, now: Time.current, health: QueueHealth.new(now:))
    @booted = booted
    @now = now
    @health = health
  end

  # One check. Returns :restart, :stuck or :ok; nil when the database didn't answer.
  def tick
    problem = @health.problem
    if restart?
      # Saying so may fail (mail, Sentry); the restart happens anyway (Infra).
      begin
        Rails.error.report(RuntimeError.new("Solid Queue worker in this process stopped; restarting the process"), handled: true)
        Autopilot::Alert.raise!(KEY, title: "The job queue's worker stopped; the web process restarts itself",
          body: "#{problem || 'This process has no working job worker'}.\n\nSee Admin > Health.", deliver_now: true)
      rescue StandardError => error
        Rails.logger.error("[queue_watchdog] couldn't report the restart: #{error.class}: #{error.message}")
      ensure
        stopper.call
      end
      return :restart
    end

    if problem
      Autopilot::Alert.raise!(KEY, title: "The job queue is stuck", body: "#{problem}.\n\nSee Admin > Health.", deliver_now: true)
      :stuck
    else
      Autopilot::Alert.resolve!(KEY, note: "Jobs are running again.")
      catch_up
      :ok
    end
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.warn("[queue_watchdog] the database didn't answer (#{error.class}); waiting")
    nil
  end

  # A daily (or rarer) scheduled job whose last run time passed LATE ago without being queued (the dispatcher was
  # down) is queued once, for that run time (#811 auto-fix; Solid Queue records each run time once, so never twice).
  LATE = 15.minutes
  MAX_LATE = 1.day
  # Too heavy to run in the day on its own say-so (DQ, memory): the nightly crawl waits for its next night.
  NO_CATCH_UP = %w[daily_crawl].freeze

  def catch_up
    SolidQueue::RecurringTask.static.where.not(key: NO_CATCH_UP).filter_map do |task|
      due = task.previous_time
      next if due > @now - LATE || due < @now - MAX_LATE
      next if task.next_time_after(due) - due < 1.hour
      next if SolidQueue::RecurringExecution.exists?(task_key: task.key, run_at: due)

      Rails.logger.warn("[queue_watchdog] #{task.key} missed its #{due.iso8601} run; queued once now")
      task.key if task.enqueue(at: due)
    end
  end

  private
    # Only when the worker runs in this process (async, the default): in fork mode it has its own pid (Copilot).
    def restart?
      return false if ENV.fetch("SOLID_QUEUE_MODE", "async") != "async"
      return false if @now - @booted < GRACE

      last = QueueHealth.own_worker_heartbeat
      last.nil? || last < @now - RESTART_AFTER
    end
end
