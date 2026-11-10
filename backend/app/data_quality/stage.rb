# Base class for one pipeline stage. Every execution is recorded as a
# crawl_runs row (status, stats, error), so each stage can be traced and
# rerun on its own. Subclasses implement #perform and return a stats hash.
class DataQuality::Stage
  def self.call(**) = new(**).call

  def self.stage_name = name.demodulize.underscore

  attr_reader :plugin, :directory

  def initialize(plugin:, directory: DataQuality::DirectoryClient.new)
    @plugin = plugin
    @directory = directory
  end

  def call
    run = CrawlRun.create!(stage: self.class.stage_name, source_kind: plugin.source_kind)
    run.finish!(stats: perform(run))
    run
  rescue DataQuality::Pipeline::AlreadyRunning
    # Not a run: another one held the lock, and the job tries again later (no failed row in the history).
    run&.destroy
    raise
  rescue => error
    run&.fail!("#{error.class}: #{error.message}")
    raise
  end

  private
    def perform(run)
      raise NotImplementedError, "#{self.class} must implement #perform"
    end

    def sources
      Source.where(source_kind: plugin.source_kind)
    end

    def candidates
      Candidate.where(source: sources)
    end
end
