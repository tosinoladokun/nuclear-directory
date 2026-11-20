require "test_helper"

# P0 after 19 Nov: a dead job worker or a stuck queue alerts (email now, not via the queue) and a dead in-process
# worker restarts the process; a database blip is waited out.
class QueueWatchdogTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 11, 20, 18, 0)

  setup do
    @stopped = 0
    @stopper = QueueWatchdog.stopper
    QueueWatchdog.stopper = -> { @stopped += 1 }
    @reports = []
    Autopilot::Alert.reporter = ->(key, title, _body) { @reports << [ key, title ] }
  end

  teardown do
    QueueWatchdog.stopper = @stopper
    Autopilot::Alert.reporter = nil
  end

  def worker(beat, pid: Process.pid)
    SolidQueue::Process.create!(kind: "Worker", name: "worker-#{SecureRandom.hex(3)}", pid:, hostname: Socket.gethostname, last_heartbeat_at: beat)
  end

  def tick(booted: NOW - 1.hour) = QueueWatchdog.new(booted:, now: NOW).tick

  test "a live worker and nothing waiting is fine; a quiet worker alerts and restarts this process" do
    worker(NOW - 1.minute)
    assert_equal :ok, tick

    SolidQueue::Process.update_all(last_heartbeat_at: NOW - 11.minutes)
    assert_equal :restart, tick
    assert_equal 1, @stopped
    assert_match "worker stopped", @reports.last.last
    assert AutopilotAlert.open.exists?(key: QueueWatchdog::KEY)
  end

  test "just booted: no restart before the grace period, but a stuck queue still alerts" do
    assert_equal :stuck, tick(booted: NOW - 1.minute)
    assert_equal 0, @stopped
  end

  test "jobs waiting half an hour with none finished is stuck; one finishing clears it" do
    worker(NOW - 1.minute)
    job = SolidQueue::Job.create!(class_name: "PageWarmJob", queue_name: "default", arguments: {}, created_at: NOW - 40.minutes)
    SolidQueue::ReadyExecution.where(job_id: job.id).update_all(created_at: NOW - 40.minutes)
    SolidQueue::ReadyExecution.create!(job_id: job.id, queue_name: "default", created_at: NOW - 40.minutes) unless SolidQueue::ReadyExecution.exists?(job_id: job.id)
    assert_match "jobs are waiting to start, the oldest for 40 minutes", QueueHealth.new(now: NOW).problem
    assert_equal :stuck, tick
    assert_equal 0, @stopped

    SolidQueue::Job.create!(class_name: "PageWarmJob", queue_name: "default", arguments: {}, finished_at: NOW - 1.minute)
    assert_equal :ok, tick
    assert_not AutopilotAlert.open.exists?(key: QueueWatchdog::KEY), "resolved"
  end

  test "the database not answering is waited out: no alert, no restart" do
    down = Object.new
    def down.problem = raise(ActiveRecord::ConnectionNotEstablished, "down")
    assert_nil QueueWatchdog.new(booted: NOW - 1.hour, now: NOW, health: down).tick
    assert_equal 0, @stopped
  end
end
