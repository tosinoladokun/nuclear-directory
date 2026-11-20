# Whether the job queue is working (PM, P0 after 19 Nov: the database crash killed the Solid Queue worker and
# nothing ran for 18 hours). Checked every minute by QueueWatchdog, outside the queue, since a stuck queue can't
# run its own health job; also shown in the daily health (PipelineHealth).
#
# Stuck when no worker has checked in for HEARTBEAT, or a job has waited READY to start while none finished.
class QueueHealth
  HEARTBEAT = 10.minutes
  READY = 30.minutes

  def initialize(now: Time.current)
    @now = now
  end

  # Why the queue is stuck, in counts and minutes only, or nil.
  def problem
    unless SolidQueue::Process.where(kind: "Worker", last_heartbeat_at: (@now - HEARTBEAT)..).exists?
      return "No job worker has checked in for #{HEARTBEAT.in_minutes.to_i} minutes: nothing runs (crawl, finder, posts, page warmer)"
    end

    oldest = SolidQueue::ReadyExecution.minimum(:created_at)
    return unless oldest && oldest < @now - READY
    return if SolidQueue::Job.where(finished_at: (@now - READY)..).exists?

    waiting = SolidQueue::ReadyExecution.count
    "#{waiting} jobs are waiting to start, the oldest for #{((@now - oldest) / 60).floor} minutes, and none finished in #{READY.in_minutes.to_i}"
  end

  # This process's own in-Puma worker (SOLID_QUEUE_IN_PUMA) last checked in, or nil when it has no worker row.
  def self.own_worker_heartbeat
    SolidQueue::Process.where(kind: "Worker", pid: ::Process.pid, hostname: Socket.gethostname).maximum(:last_heartbeat_at)
  end
end
