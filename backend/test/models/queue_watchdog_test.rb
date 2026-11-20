require "test_helper"

# P0 after 19 Nov: a dead job worker or a stuck queue alerts (email now, not via the queue) and a dead in-process
# worker restarts the process; a database blip is waited out.
class QueueWatchdogTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
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

  test "in fork mode the worker has its own pid: no restart, the stuck check still runs (Copilot)" do
    ENV["SOLID_QUEUE_MODE"] = "fork"
    worker(NOW - 1.minute, pid: Process.pid + 1)
    assert_equal :ok, tick
    assert_equal 0, @stopped
  ensure
    ENV.delete("SOLID_QUEUE_MODE")
  end

  test "the stuck alert's email is sent during the call, not queued (Copilot)" do
    ENV["RESEND_API_KEY"] = "test"
    ActionMailer::Base.deliveries.clear
    assert_no_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      assert_equal :stuck, tick(booted: NOW - 1.minute)
    end
    assert_equal 1, ActionMailer::Base.deliveries.size
    assert_match "[autopilot] The job queue is stuck", ActionMailer::Base.deliveries.last.subject
  ensure
    ENV.delete("RESEND_API_KEY")
  end

  test "the daily health job sends the queue-stuck email now too (Copilot)" do
    calls = []
    alert = Module.new
    alert.define_singleton_method(:raise!) { |key, **options| calls << [ key, options[:deliver_now] ] }
    alert.define_singleton_method(:resolve!) { |*, **| }
    PipelineHealthJob.alerts = alert
    PipelineHealthJob.perform_now
    assert_includes calls, [ QueueWatchdog::KEY, true ]
  ensure
    PipelineHealthJob.alerts = nil
  end

  test "a failing alert never stops the restart (Infra)" do
    worker(NOW - 11.minutes)
    Autopilot::Alert.singleton_class.alias_method(:original_raise!, :raise!)
    Autopilot::Alert.define_singleton_method(:raise!) { |*, **| raise "mail down" }
    assert_equal :restart, tick
    assert_equal 1, @stopped
  ensure
    Autopilot::Alert.singleton_class.alias_method(:raise!, :original_raise!)
  end

  test "a daily job that missed its run time is queued once; a frequent one, the nightly crawl or one already run isn't (#811)" do
    adapter = PageWarmJob.queue_adapter
    PageWarmJob.queue_adapter = :solid_queue # as in production, where each run time is recorded once
    travel_to NOW do
      worker(NOW - 1.minute)
      SolidQueue::RecurringTask.create!(key: "daily_test", class_name: "PageWarmJob", schedule: "every day at 9am UTC", static: true)
      SolidQueue::RecurringTask.create!(key: "often_test", class_name: "PageWarmJob", schedule: "every 5 minutes", static: true)
      SolidQueue::RecurringTask.create!(key: "daily_crawl", class_name: "PageWarmJob", schedule: "every day at 9am UTC", static: true)
      watchdog = QueueWatchdog.new(booted: NOW - 1.hour, now: NOW)
      SolidQueue::RecurringTask.create!(key: "daily_test_2", class_name: "PageWarmJob", schedule: "every day at 8am UTC", static: true)
      assert_equal [ "daily_test_2" ], watchdog.catch_up, "one a tick, oldest first (Infra)"
      assert_equal [ "daily_test" ], watchdog.catch_up
      assert_empty watchdog.catch_up, "never twice for the same run time"
    end
  ensure
    PageWarmJob.queue_adapter = adapter
  end

  test "nothing is caught up into a paused queue (Infra)" do
    travel_to NOW do
      SolidQueue::RecurringTask.create!(key: "daily_paused", class_name: "PageWarmJob", schedule: "every day at 9am UTC", static: true)
      SolidQueue::Pause.create!(queue_name: PageWarmJob.queue_name)
      assert_empty QueueWatchdog.new(booted: NOW - 1.hour, now: NOW).catch_up
    end
  end
end
