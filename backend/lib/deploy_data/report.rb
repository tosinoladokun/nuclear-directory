module DeployData
  # The data step's report, as plain text: printed to the deploy log, posted
  # on the PR, and printed the same way by a --dry-run rehearsal, so Data
  # Quality can compare the two line for line.
  class Report
    attr_accessor :outcome, :backup, :seed_check, :seed, :seed_counts, :rows_before, :rows_after,
      :seed_events, :migration_events, :totals_before, :totals_after, :migrations, :flags, :notes
    attr_reader :pull_request
    # An error after the data committed: the outcome stands, but it alerts.
    attr_accessor :after_commit_error

    # label: "Data deploy", "Report mode (…)" or "Dry run (…)".
    def initialize(commit:, pull_request:, label:)
      @commit = commit
      @pull_request = pull_request
      @label = label
      @migrations = []
      @flags = []
      @notes = []
    end

    def alert? = outcome.to_s.start_with?("stopped", "failed") || flags.any? || after_commit_error.present?

    def title = "#{@label} #{@commit.to_s[0, 7].presence || 'unknown commit'}: #{outcome}"

    def to_s
      lines = [ [ @label, @commit.to_s[0, 7].presence, ("(PR ##{@pull_request})" if @pull_request) ].compact.join(" ") + ": #{outcome}" ]
      lines << "Backup: #{backup}" if backup
      lines << "seed:check: #{seed_check}" if seed_check
      lines << "Seed: #{seed}" if seed
      if seed_counts.present?
        lines << "Seed counts, from the loader:"
        seed_counts.each { |kind, counts| lines << "  #{kind.to_s.ljust(26)} #{counts.map { |name, n| "#{n} #{name}" }.join(', ')}" }
      end
      if rows_before && rows_after
        lines << "Rows, before -> after:"
        rows_after.each_key { |table| lines << "  #{table.ljust(26)} #{change(rows_before[table], rows_after[table])}" }
      end
      [ [ "Verification events written by the seed", seed_events ], [ "Verification events written by data migrations", migration_events ] ].each do |label, events|
        next unless events
        lines << "#{label}: #{events.values.sum}"
        events.sort.each { |type, n| lines << "  #{type.ljust(26)} #{n}" }
      end
      if totals_before && totals_after
        lines << "Public totals, before -> after:"
        totals_after.each_key { |name| lines << "  #{name.ljust(26)} #{change(totals_before[name], totals_after[name])}" }
      end
      unless migrations.empty?
        lines << "Data migrations:"
        migrations.each do |ran|
          lines << "  #{ran.version} #{ran.name} (by #{ran.by})"
          ran.output.each { |line| lines << "    #{line}" }
        end
      end
      unless flags.empty?
        lines << "Flag: events for records whose files didn't change (#{flags.size}):"
        flags.each { |flag| lines << "  #{flag}" }
      end
      lines << "Error after the data committed (it stands): #{after_commit_error}" if after_commit_error
      notes.each { |note| lines << "Note: #{note}" }
      lines.join("\n")
    end

    def to_markdown
      lead = alert? ? "**Needs a look:** #{outcome}." : "**#{outcome.to_s.upcase_first}.**"
      "#{lead} Data Quality: compare with the PR's rehearsal output.\n\n```text\n#{self}\n```\n\n" \
        "From `bin/deploy-data` in Render's pre-deploy step (#301)."
    end

    private
      def change(before, after)
        delta = after.to_i - before.to_i
        "#{before} -> #{after}#{format('  (%+d)', delta) unless delta.zero?}"
      end
  end
end
