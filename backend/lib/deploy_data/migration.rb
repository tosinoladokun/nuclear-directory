module DeployData
  # A one-off data fix, run once by the deploy's data step (#301) after the
  # seed. One file per fix in db/data/, named <timestamp>_<name>.rb:
  #
  #   # db/data/20261017120000_palisades_not_operating.rb
  #   class PalisadesNotOperating < DeployData::Migration
  #     BY = "human:tosin"   # who approved it; merging the PR is the approval
  #
  #     def up
  #       say Directory::Ops.set_status(ids: [ 42 ], status: "not_operating", by: BY, reason:, quote: QUOTE)
  #     end
  #   end
  #
  # Rules (Data Quality and Backend, #301):
  # - BY names the human who approved it ("human:<name>"), never the deploy,
  #   so its writes are final for the pipeline (protect_human_verified).
  #   `reason` gives the deploy commit and PR for the audit trail.
  # - Idempotent: a rerun on data it already fixed changes nothing.
  # - Pin what the decision rests on (an id, a quote) and raise if it's no
  #   longer true, rather than guess.
  # - Rehearsed with `bin/deploy-data --dry-run` on a restored backup before
  #   merge; `say` what it changes so the rehearsal and deploy logs match.
  # - Never stop the deploy on a record a person may decide first (#811):
  #   accept the decided state, or skip and `say` why.
  # - A step that builds on another says so: AFTER = %w[<version>] (the other's
  #   14-digit timestamp). It is skipped, and reported as waiting, until each is
  #   recorded as run, so a failed or missing predecessor never lets it apply.
  # - Never rescue a database error inside `up`: let it raise. A swallowed
  #   error leaves Postgres' transaction aborted, so the step's savepoint can't
  #   roll back cleanly and every later statement fails (Backend's review, #813).
  # - A job it queues waits past the release switch: queue_after_deploy(Job,
  #   *args), never Job.perform_later. The step runs in Render's pre-deploy,
  #   while the old release's worker still runs; a job queued at once runs on
  #   the old code (#1018: #1016's re-queued finds ran the old finder).
  # It runs in the deploy's transaction with the seed and the other new
  # migrations, each in its own savepoint (#811): one that raises is rolled
  # back alone, reported and tried again at the next deploy; the others and
  # the seed commit, and each is recorded as run only when it succeeds. Never
  # from db:prepare, db:schema:load or tests: only bin/deploy-data runs it.
  class Migration
    HUMAN = /\Ahuman:[a-z0-9_.-]+\z/

    attr_reader :output

    def initialize(reason:)
      @reason = reason
      @output = []
    end

    # "deploy abc1234, PR #298", for the reason of every write.
    attr_reader :reason

    def by = self.class::BY

    def up = raise(NotImplementedError, "#{self.class.name} must define up")

    # Long enough for the new release to take over from the old one, whose
    # worker would otherwise run the job on the old code (#1018).
    AFTER_DEPLOY_WAIT = 15.minutes

    # Queues a job to run once the new release serves (#1018).
    def queue_after_deploy(job, *args) = job.set(wait: AFTER_DEPLOY_WAIT).perform_later(*args)

    def say(message)
      Array(message).each do |line|
        @output << line.to_s
        puts "  #{line}"
      end
    end

    def self.subclasses_defined = (@defined ||= [])

    def self.inherited(subclass)
      super
      Migration.subclasses_defined << subclass
    end
  end
end
