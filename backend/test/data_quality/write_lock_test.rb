require "test_helper"
require "rake"
require_relative "support/fake_directory"
require_relative "support/dummy_plugin"

# The data write lock (#301): crawls share it, a deploy's data steps take it
# alone.
class DataQuality::WriteLockTest < ActiveSupport::TestCase
  KEY = DataQuality::WriteLock::KEY

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("data_quality:with_write_lock")
  end

  def run_crawl = DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, directory: FakeDirectory.client, only: "crawl")

  # A separate Postgres session, like another worker or the deploy would have.
  def other_session
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: config[:host], port: config[:port], dbname: config[:database],
      user: config[:username], password: config[:password])
  end

  def close_session(session)
    return unless session

    session.exec("SELECT pg_advisory_unlock_all()")
    session.close
  end

  def try(session, function) = session.exec("SELECT #{function}(#{KEY})").getvalue(0, 0) == "t"

  test "a crawl doesn't start while a deploy holds the lock, and is retried like a run in progress" do
    deploy = other_session
    assert try(deploy, "pg_try_advisory_lock"), "the deploy takes the lock"

    error = assert_raises(DataQuality::Pipeline::AlreadyRunning) { run_crawl }
    assert_match "data is being deployed", error.message
    assert_equal 0, CrawlRun.where(source_kind: "dummy").count, "nothing ran"
  ensure
    close_session(deploy)
  end

  test "crawls share the lock, so one runs while another holds it" do
    crawl = other_session
    assert try(crawl, "pg_try_advisory_lock_shared"), "another crawl holds it shared"

    assert run_crawl.sole.succeeded?
  ensure
    close_session(crawl)
  end

  test "a crawl releases the lock when it finishes, even when it fails" do
    broken = DummyPlugin.new
    def broken.crawl(_run) = raise("site is down")
    assert_raises(RuntimeError) { DataQuality::Pipeline.run("dummy", plugin: broken, only: "crawl") }

    deploy = other_session
    assert try(deploy, "pg_try_advisory_lock"), "the deploy can take it alone"
  ensure
    close_session(deploy)
  end

  test "the deploy waits for a running crawl, then gives up after its timeout" do
    crawl = other_session
    assert try(crawl, "pg_try_advisory_lock_shared")

    ran = false
    error = assert_raises(DataQuality::WriteLock::Busy) do
      DataQuality::WriteLock.exclusive(timeout: 0.2.seconds, poll: 0.05) { ran = true }
    end
    assert_match "a crawl still holds the data write lock", error.message
    assert_not ran
  ensure
    close_session(crawl)
  end

  test "the deploy holds the lock alone while its block runs, and releases it after" do
    crawl = other_session
    DataQuality::WriteLock.exclusive(timeout: 1.second, poll: 0.05) do
      assert_not try(crawl, "pg_try_advisory_lock_shared"), "no crawl can start meanwhile"
    end
    assert try(crawl, "pg_try_advisory_lock_shared"), "crawls can start again"
  ensure
    close_session(crawl)
  end

  test "with_write_lock runs the given tasks in order, holding the lock" do
    crawl = other_session
    seen = []
    Rake::Task.define_task("write_lock_test:one") { seen << [ :one, try(crawl, "pg_try_advisory_lock_shared") ] }
    Rake::Task.define_task("write_lock_test:two") { seen << [ :two, try(crawl, "pg_try_advisory_lock_shared") ] }

    ENV["TASKS"] = "write_lock_test:one write_lock_test:two"
    Rake::Task["data_quality:with_write_lock"].execute

    assert_equal [ [ :one, false ], [ :two, false ] ], seen
    assert try(crawl, "pg_try_advisory_lock_shared"), "released after the tasks"
  ensure
    ENV.delete("TASKS")
    Rake::Task.tasks.select { |task| task.name.start_with?("write_lock_test:") }.each(&:clear)
    close_session(crawl)
  end

  test "with_write_lock refuses to run without tasks" do
    ENV.delete("TASKS")
    assert_raises(SystemExit) do
      assert_output(nil, /Usage: TASKS=/) { Rake::Task["data_quality:with_write_lock"].execute }
    end
  end

  test "the approve-all repair task doesn't run during a deploy's data steps (#308)" do
    deploy = other_session
    assert try(deploy, "pg_try_advisory_lock")

    assert_raises(SystemExit) do
      assert_output(nil, /Not run: data is being deployed/) { Rake::Task["data_quality:repair_approve_all"].execute }
    end
  ensure
    close_session(deploy)
  end
end
