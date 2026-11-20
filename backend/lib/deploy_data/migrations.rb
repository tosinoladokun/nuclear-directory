module DeployData
  # Finds and runs the data migrations in db/data/ that haven't run yet,
  # oldest first. See DeployData::Migration for the rules.
  class Migrations
    FILE = /\A(\d{14})_([a-z0-9_]+)\.rb\z/

    Pending = Data.define(:version, :name, :path)
    Ran = Data.define(:version, :name, :by, :output)
    class Invalid < StandardError; end
    # A step that declares AFTER = [versions] while one of them hasn't run (yet, or at all): skipped, reported, tried again.
    class Waiting < StandardError; end

    def initialize(dir = Rails.root.join("db/data"))
      @dir = dir.to_s
    end

    def pending
      done = DataMigration.pluck(:version).to_set
      Dir.children(@dir).sort.filter_map do |file|
        next unless file.end_with?(".rb")
        match = FILE.match(file) or raise Invalid, "db/data/#{file}: name it <14-digit timestamp>_<snake_case_name>.rb"
        Pending.new(version: match[1], name: match[2], path: File.join(@dir, file)) unless done.include?(match[1])
      end
    rescue Errno::ENOENT
      []
    end

    # Runs one, in a transaction with its record (a savepoint inside the
    # caller's, when there is one, so a failure rolls back only this one and
    # not the others). Raises on any error; rolled back, it runs again on the
    # next deploy.
    def run(pending, reason:, commit:)
      klass = load_class(pending)
      migration = klass.new(reason:)
      by = migration.by.to_s
      raise Invalid, "db/data/#{File.basename(pending.path)}: BY must name the human who approved it, like \"human:tosin\" (got #{by.inspect})" unless by.match?(Migration::HUMAN)

      waiting = predecessors(klass) - DataMigration.pluck(:version)
      raise Waiting, "waiting for #{waiting.join(', ')} to run first" if waiting.any?

      puts "Data migration #{pending.version} #{pending.name} (by #{by}):"
      ActiveRecord::Base.transaction(requires_new: true) do
        migration.up
        DataMigration.create!(version: pending.version, name: pending.name, by:, reason:, commit:,
          output: migration.output.join("\n"), ran_at: Time.current)
      end
      Ran.new(version: pending.version, name: pending.name, by:, output: migration.output)
    end

    private
      # AFTER = %w[20261109120000] on a migration: it only runs once those versions are recorded as run (earlier,
      # or earlier in this same run), so a step that builds on another is never applied without it (#669 -> #673).
      def predecessors(klass) = Array(klass.const_defined?(:AFTER) ? klass::AFTER : []).map(&:to_s)

      # Each file is loaded into its own anonymous module, so a class name
      # can't clash with the app's or another migration's.
      def load_class(pending)
        before = Migration.subclasses_defined.size
        load pending.path, true
        defined = Migration.subclasses_defined[before..]
        raise Invalid, "db/data/#{File.basename(pending.path)} must define exactly one DeployData::Migration subclass" unless defined.size == 1
        defined.first
      end
  end
end
