# The one lock every writer of the directory's data shares (#301): crawl
# runs take it shared, so several kinds still run at once; bin/deploy-data
# takes it exclusively for its data steps (seed:check, db:seed, data
# migrations), so those never write while a crawl does, and no crawl starts
# while they run. A Postgres advisory lock on this connection, held for the
# block. Each pipeline run keeps its own per-kind lock too (Pipeline).
#
#   DataQuality::WriteLock.shared { … }                     # raises Busy during a deploy
#   DataQuality::WriteLock.exclusive(timeout: 30.minutes) { … } # waits for running crawls
module DataQuality::WriteLock
  KEY = Zlib.crc32("data_quality:writes")

  class Busy < StandardError; end

  # Yields holding the lock shared, or raises Busy when a deploy holds it.
  def self.shared
    raise Busy, "data is being deployed; try again when it finishes" unless try("pg_try_advisory_lock_shared")

    begin
      yield
    ensure
      unlock("pg_advisory_unlock_shared")
    end
  end

  # Waits until no crawl holds it (checking every poll seconds, up to
  # timeout), then yields holding it exclusively; raises Busy on timeout.
  def self.exclusive(timeout: 30.minutes, poll: 5)
    deadline = Time.current + timeout
    until try("pg_try_advisory_lock")
      raise Busy, "a crawl still holds the data write lock after #{timeout.inspect}" if Time.current >= deadline

      sleep poll
    end
    begin
      yield
    ensure
      unlock("pg_advisory_unlock")
    end
  end

  def self.try(function) = connection.select_value("SELECT #{function}(#{KEY})")
  def self.unlock(function) = connection.select_value("SELECT #{function}(#{KEY})")
  def self.connection = CrawlRun.connection
  private_class_method :try, :unlock, :connection
end
