# Runs stages for one source kind, in order:
#   crawl → extract → match → verify (publish or review)
# Each stage reads its input from the database and writes its output back,
# so any stage can be rerun alone: Pipeline.run("nrc_reactor_list", only: "match").
#
# Only one run per source kind at a time, and none while a deploy's data
# steps run (DataQuality::WriteLock, #301): a Postgres advisory lock is held
# for the whole run, so a second run (a manual one during the scheduled
# one, say) stops with AlreadyRunning instead of racing the first. Each run
# starts by marking runs of its kind left "running" by a process that died as
# failed (see sweep_abandoned).
class DataQuality::Pipeline
  STAGES = {
    "crawl" => DataQuality::Stages::Crawl,
    "extract" => DataQuality::Stages::Extract,
    "match" => DataQuality::Stages::Match,
    "verify" => DataQuality::Stages::Verify
  }.freeze

  # The stages that work from the stored snapshot, without fetching anything.
  FROM_SNAPSHOT = %w[extract match verify].freeze
  ABANDONED = "Abandoned: the process running it stopped (a restart, or running out of memory), " \
    "so it never finished. Rerun it."

  class AlreadyRunning < StandardError; end

  # Returns the CrawlRun of each stage that ran. Stops at the first stage
  # that fails (its run is marked failed and the error is raised).
  def self.run(source_kind, only: nil, plugin: DataQuality::Plugin.for(source_kind),
    directory: DataQuality::DirectoryClient.new, verifier: nil)
    stage_names = only ? Array(only).map(&:to_s) : STAGES.keys
    unknown = stage_names - STAGES.keys
    raise ArgumentError, "Unknown stage(s): #{unknown.join(', ')}" if unknown.any?

    # Shared with every other run, exclusive of a deploy's data steps (#301).
    DataQuality::WriteLock.shared do
      with_lock(plugin.source_kind) do
        sweep_abandoned(plugin.source_kind)

        stage_names.map do |name|
          options = { plugin: plugin, directory: directory }
          options[:verifier] = verifier if name == "verify" && verifier
          STAGES.fetch(name).call(**options)
        end
      end
    end
  rescue DataQuality::WriteLock::Busy => error
    # Retried like a run already in progress (DailyCrawlJob, CatchUpJob).
    raise AlreadyRunning, error.message
  end

  # Every run is made inside its source kind's lock, so while the lock is
  # held, any run of that kind still "running" belongs to a process that
  # died (#188: Render restarted the instance mid-crawl). Marks them failed;
  # returns how many. Call it holding the lock.
  def self.sweep_abandoned(source_kind)
    stale = CrawlRun.running.where(source_kind: source_kind).to_a
    stale.each { |run| run.fail!(ABANDONED) }
    stale.size
  end

  # The same for every source kind not being run right now, without waiting
  # for its next run: from the hourly catch-up (CatchUpJob). A kind whose
  # lock is held is mid-run, so it's left alone.
  def self.sweep_all_abandoned
    CrawlRun.running.distinct.pluck(:source_kind).sum do |source_kind|
      try_lock(source_kind) { sweep_abandoned(source_kind) } || 0
    end
  end

  def self.with_lock(source_kind)
    held = false
    result = try_lock(source_kind) { held = true; yield }
    raise AlreadyRunning, "A #{source_kind} pipeline run is already in progress; try again when it finishes" unless held

    result
  end
  private_class_method :with_lock

  # Yields holding the source kind's lock and returns the block's value, or
  # returns false without yielding when another session holds it.
  def self.try_lock(source_kind)
    key = Zlib.crc32("data_quality:#{source_kind}")
    connection = CrawlRun.connection
    return false unless connection.select_value("SELECT pg_try_advisory_lock(#{key})")

    begin
      yield
    ensure
      connection.select_value("SELECT pg_advisory_unlock(#{key})")
    end
  end
  private_class_method :try_lock
end
