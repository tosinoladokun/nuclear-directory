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
      Rails.error.report(RuntimeError.new("Solid Queue worker in this process stopped; restarting the process"), handled: true)
      Autopilot::Alert.raise!(KEY, title: "The job queue's worker stopped; the web process restarts itself",
        body: "#{problem || 'This process has no working job worker'}.\n\nSee Admin > Health.", deliver_now: true)
      stopper.call
      return :restart
    end

    if problem
      Autopilot::Alert.raise!(KEY, title: "The job queue is stuck", body: "#{problem}.\n\nSee Admin > Health.", deliver_now: true)
      :stuck
    else
      Autopilot::Alert.resolve!(KEY, note: "Jobs are running again.")
      :ok
    end
  rescue ActiveRecord::ActiveRecordError => error
    Rails.logger.warn("[queue_watchdog] the database didn't answer (#{error.class}); waiting")
    nil
  end

  private
    def restart?
      return false if @now - @booted < GRACE

      last = QueueHealth.own_worker_heartbeat
      last.nil? || last < @now - RESTART_AFTER
    end
end
