require "zlib"

module DeployData
  # Keeps the data step and the daily crawl from writing at the same time:
  # holds every pipeline lock (DataQuality::Pipeline.try_lock takes one per
  # source kind) plus the shared data_quality:writes lock, or none. Each is
  # a session-level Postgres advisory lock on this process's connection.
  module CrawlLock
    module_function

    def names
      kinds = Dir.glob("*.rb", base: Rails.root.join("app/data_quality/plugins").to_s).map { |file| File.basename(file, ".rb") }
      [ "writes", *kinds, *CrawlRun.distinct.pluck(:source_kind) ].uniq.map { |kind| "data_quality:#{kind}" }
    end

    # Yields with every lock held and returns true, or returns false (and
    # yields nothing) when the crawl holds any of them.
    def hold(names: self.names)
      connection = ActiveRecord::Base.connection
      held = []
      names.each do |name|
        key = Zlib.crc32(name)
        # Uncached: the query cache would answer a second try from the first.
        return false unless connection.uncached { connection.select_value("SELECT pg_try_advisory_lock(#{key})") }
        held << key
      end
      yield
      true
    ensure
      held&.each { |key| connection.uncached { connection.select_value("SELECT pg_advisory_unlock(#{key})") } }
    end
  end
end
