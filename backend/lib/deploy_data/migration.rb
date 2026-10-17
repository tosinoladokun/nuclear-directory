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
  # It runs in the deploy's transaction with the seed and the other new
  # migrations, recorded as run only if they all succeed. Never
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
