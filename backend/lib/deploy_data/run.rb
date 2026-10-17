module DeployData
  # The deploy's data step (#301), run by bin/deploy-data in Render's
  # pre-deploy step after db:migrate. In order:
  #
  # 1. Nothing to do unless the seed files (or the code that loads them)
  #    changed since the last run, or a db/data/ migration is new.
  # 2. Hold the crawl's locks, or stop: never write during the daily crawl.
  # 3. Take a fresh encrypted backup; stop if it fails.
  # 4. seed:check; stop on any collision.
  # 5. db:seed, then
  # 6. each new data migration, all in one transaction: if any fails,
  #    nothing from 5 or 6 is written and the next deploy runs them all
  #    again (so a migration's fix is never left out after a re-seed).
  # 7. Report: deploy log, a comment on the PR, and Sentry when it needs a look.
  #
  # "Stop" writes nothing, alerts, and lets the code deploy go on.
  #
  # AUTO_DATA_DEPLOY (set in the dashboard) picks the mode:
  # - "on": all of the above.
  # - "report": the backup, then steps 4 to 6 in a transaction that's rolled
  #   back, and the would-be report on the PR, while the steps are still done
  #   by hand. Run for a few data PRs and compare before switching to "on".
  # - anything else, or blank: off (the kill switch).
  #
  # dry_run: Data Quality's rehearsal on a restored backup. Steps 4 to 6,
  # rolled back; no backup, record or post, whatever the mode.
  class Run
    class Stop < StandardError; end
    # Not a StandardError, so no recoverable-error rescue (a GitHub lookup, a
    # migration) can swallow it and let the run go on past its deadline.
    class TimedOut < Interrupt; end
    class MigrationFailed < StandardError; end

    MODES = %w[on report].freeze
    SEED_COUNTS = "tmp/seed_counts.json".freeze

    attr_reader :report

    def initialize(dry_run: false, commit: ENV["RENDER_GIT_COMMIT"], mode: ENV["AUTO_DATA_DEPLOY"],
      backup: Backup, github: GitHub.new, migrations: Migrations.new, root: Rails.root, lock: CrawlLock,
      seeder: -> { Rails.application.load_seed },
      checker: -> { Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations")).collisions })
      @dry_run = dry_run
      @mode = MODES.include?(mode.to_s.strip) ? mode.to_s.strip : "off"
      @commit = commit.presence
      @backup = backup
      @github = github
      @migrations = migrations
      @root = root
      @lock = lock
      @seeder = seeder
      @checker = checker
    end

    # Returns :disabled, :nothing, :applied, :reported, :stopped or :failed
    # (:reported for a dry run that got to the end).
    def call
      if !@dry_run && @mode == "off"
        puts "deploy-data: off (AUTO_DATA_DEPLOY isn't \"on\" or \"report\"); the seed and data migrations didn't run."
        return :disabled
      end

      @started_at = Time.current
      @fingerprint = Fingerprint.current(@root)
      @last = DataDeploy.baseline(report_mode: report_mode?)
      @changed = @fingerprint.changed_since(@last&.files)
      @seed_changed = @last.nil? || @last.seed_digest != @fingerprint.digest
      @pending = @migrations.pending
      @pending = @pending.reject { |pending| DataDeploy.reported_migrations.include?(pending.version) } if report_mode?
      unless @seed_changed || @pending.any?
        puts "deploy-data: nothing to do (the seed is unchanged since #{short(@last.commit)} and no data migrations are new)."
        return :nothing
      end

      pull_request = @github.pull_request_for(@commit)
      @reason = [ "deploy #{short(@commit)}", ("PR ##{pull_request}" if pull_request) ].compact.join(", ")
      @report = Report.new(commit: @commit, pull_request:, label:)
      @status = rolled_back? ? :reported : :applied

      held = @lock.hold { steps }
      stop!("stopped: the daily crawl is running, so nothing was written; it runs again on the next deploy") unless held
      finish
    rescue Stop
      finish
    rescue TimedOut, StandardError, ScriptError => error
      @report ||= Report.new(commit: @commit, pull_request: nil, label:)
      # After the commit (releasing the crawl's locks, an after_commit
      # callback), the data and its applied record are already in: say so,
      # rather than report a failure for writes that stand.
      if committed?
        @report.after_commit_error = "#{error.class.name.demodulize}: #{error.message.lines.first&.strip}"
        return finish
      end

      @status = :failed
      first, *rest = error.message.lines.map(&:strip).compact_blank
      @report.outcome = "failed: #{error.class.name.demodulize}: #{first}"
      # The loader lists the failing facts after its first line.
      @report.notes.concat(rest)
      @error = error.full_message(highlight: false)
      finish
    end

    private
      def report_mode? = !@dry_run && @mode == "report"
      def rolled_back? = @dry_run || report_mode?

      def label
        if @dry_run then "Dry run (rolled back)"
        elsif report_mode? then "Report mode (rolled back; apply by hand)"
        else "Data deploy"
        end
      end

      def short(commit) = commit.to_s[0, 7].presence || "unknown"

      def steps
        take_backup
        check if @seed_changed
        in_one_transaction do
          @report.rows_before = Census.rows
          @report.totals_before = Census.public_totals
          seed if @seed_changed
          @report.seed ||= "skipped (unchanged since #{short(@last.commit)})"
          migrate
          @report.rows_after = Census.rows
          @report.totals_after = Census.public_totals
          @report.outcome = rolled_back? ? "would apply" : "applied"
          # The applied record is the next run's baseline, so it commits with
          # the data it describes or not at all (a failed insert rolls the
          # data back too, and the next deploy runs it all again).
          create_record! unless rolled_back?
        end
      end

      def take_backup
        @report.backup = @dry_run ? "skipped (dry run)" : @backup.take!
      rescue Backup::Failed => error
        stop!("stopped: #{error.message}, so nothing was written")
      end

      def check
        collisions = @checker.call
        @report.seed_check = collisions.empty? ? "no collisions" : "#{collisions.size} #{'collision'.pluralize(collisions.size)}"
        return if collisions.empty?

        @report.notes.concat(collisions)
        stop!("stopped: seed:check found collisions, so nothing was written")
      end

      def seed
        first_event = Census.last_event_id
        counts_file = @root.join(SEED_COUNTS)
        File.delete(counts_file) if File.exist?(counts_file)
        log = capturing_output { ActiveRecord::Base.transaction { @seeder.call } }
        @report.seed = @last ? "ran (#{@changed.size} #{'file'.pluralize(@changed.size)} changed since #{short(@last.commit)})" : "ran (first automatic run)"
        @report.seed_counts = File.exist?(counts_file) ? JSON.parse(File.read(counts_file)) : SeedLog.counts(log)

        events = VerificationEvent.where("id > ?", first_event).to_a
        @report.seed_events = events.map(&:subject_type).tally
        flip_flops(events)
      end

      # Runs the block, printing its output as usual and returning it too.
      def capturing_output
        original = $stdout
        captured = StringIO.new
        $stdout = SeedLog::Tee.new(original, captured)
        yield
        captured.string
      ensure
        $stdout = original
      end

      # Compared with the last applied run, never a reported one: a report
      # rolled back, so the files it saw changed are still pending in the data,
      # and re-writing them now isn't a flip-flop.
      def flip_flops(events)
        applied = DataDeploy.baseline(report_mode: false)
        if applied.nil?
          @report.notes << "no applied run yet: there's no file list to compare with, so flip-flops can't be told from changes"
        else
          changed = @fingerprint.changed_since(applied.files)
          @report.flags = FlipFlops.find(events, changed:)
          if Fingerprint.code_changed?(changed) && @report.flags.any?
            @report.notes << "the seed's code changed (#{changed.grep(Fingerprint::CODE).join(', ')}), so flagged events may be expected"
          end
        end
      end

      def migrate
        first_event = Census.last_event_id
        @pending.each do |pending|
          @report.migrations << @migrations.run(pending, reason: @reason, commit: @commit)
        rescue StandardError, ScriptError => error
          raise MigrationFailed, "data migration #{pending.version} #{pending.name}: #{error.class.name}: #{error.message}"
        end
        @report.migration_events = VerificationEvent.where("id > ?", first_event).pluck(:subject_type).tally if @pending.any?
      end

      # The seed and data migrations commit together, or (a rehearsal) not at
      # all. Repeatable read: every count and event the report reads comes from
      # one snapshot plus this run's own writes, so an admin approval committed
      # meanwhile isn't counted as the seed's (and if it touches a row the seed
      # writes, Postgres stops the run, which the next deploy retries). Inside
      # an open transaction (tests) the isolation can't be set, so it's left.
      def in_one_transaction
        isolation = :repeatable_read unless ActiveRecord::Base.connection.transaction_open?
        ActiveRecord::Base.transaction(isolation:) do
          yield
          raise ActiveRecord::Rollback if rolled_back?
        end
      end

      def stop!(outcome)
        @status = :stopped
        @report.outcome = outcome
        raise Stop
      end

      def finish
        puts @report
        return @status if @dry_run

        record unless @recorded
        url = @github.post(@report.to_markdown, pull_request: @report.pull_request, title: @report.title)
        puts "Report posted: #{url}" if url
        # A report that didn't reach the PR goes to Sentry, so it's never missed.
        alert(posted: !url.nil?) if @report.alert? || url.nil?
        @status
      end

      def create_record!
        backup_tag = @report.backup if @report.backup.to_s.start_with?("backup-")
        record = DataDeploy.create!(commit: @commit, status: @status, backup_tag:,
          seed_digest: @fingerprint&.digest, files: @fingerprint&.files || {},
          report: { text: @report.to_s, migrations: @report.migrations.map(&:version) },
          error: @error, started_at: @started_at || Time.current, finished_at: Time.current)
        @record_id = record.id
        @recorded = true
      end

      # Whether this run's applied record is in the database: read back, not
      # assumed, since it's created before the transaction commits.
      def committed?
        @record_id.present? && !rolled_back? && DataDeploy.applied.exists?(id: @record_id)
      end

      # Stopped, failed and report-mode runs: nothing they record is a baseline
      # for "on", so a failure here is only logged.
      def record
        create_record!
      rescue StandardError => error
        warn "deploy-data: couldn't record the run: #{error.message}"
      end

      def alert(posted:)
        return unless defined?(Sentry) && Sentry.initialized?

        problem = @report.alert? ? @report.outcome : "#{@report.outcome}, but the report wasn't posted on GitHub"
        problem += " (the report wasn't posted on GitHub)" if @report.alert? && !posted
        Sentry.capture_message("Data deploy needs a look: #{problem}", level: @status == :failed || @status == :stopped ? :error : :warning,
          extra: { report: @report.to_s })
      end
  end
end
