require "test_helper"
require "ripper"

# Keeps DataQuality self-contained (decision in #1): it may use its own
# models (Source, CrawlRun, Candidate), and reach the directory only through
# DataQuality::DirectoryClient, which wraps Directory::Lookup and
# Directory::FactWriter. This test reads the module's source and fails on
# anything else.
class DataQuality::BoundaryTest < ActiveSupport::TestCase
  MODULE_FILES = [ "app/data_quality/**/*.rb", "lib/tasks/data_quality.rake" ]
  # DqAction: Data Quality's own log of its matching actions on claims (#548).
  OWNED_MODELS = %w[Source CrawlRun Candidate DqAction].freeze
  # The one file allowed to name Directory:: interfaces.
  DOOR = "app/data_quality/directory_client.rb"
  # Files allowed to turn strings into constants (plug-in lookup, the door).
  CONSTANTIZE_ALLOWED = [ DOOR, "app/data_quality/plugin.rb" ].freeze

  class Checker
    def initialize(forbidden_models)
      @forbidden_models = forbidden_models
    end

    # Returns ["path:line: message", ...] for one file's source.
    def violations(code, path)
      tokens = Ripper.lex(code).map { |(line, _col), type, text| [ line, type, text ] }
        .reject { |_line, type, _text| %i[on_sp on_nl on_ignored_nl on_comment on_embdoc on_embdoc_beg on_embdoc_end].include?(type) }

      tokens.each_with_index.filter_map do |(line, type, text), i|
        prev = tokens[i - 1] if i.positive?
        before_prev = tokens[i - 2] if i > 1

        case type
        when :on_const
          # Only the first segment of a constant path matters: Directory::Organization
          # is a Directory interface, Organization alone is the model.
          nested = prev&.dig(2) == "::" && %i[on_const on_ident].include?(before_prev&.dig(1))
          next if nested

          if @forbidden_models.include?(text)
            "#{path}:#{line}: uses directory model #{text}; go through DataQuality::DirectoryClient"
          elsif text == "Directory" && path != DOOR
            "#{path}:#{line}: uses Directory:: directly; only #{DOOR} may"
          end
        when :on_ident
          if text == "subject" && prev&.dig(2) == "."
            "#{path}:#{line}: .subject loads a directory record; use subject_type / subject_id"
          elsif %w[constantize safe_constantize].include?(text) && !CONSTANTIZE_ALLOWED.include?(path)
            "#{path}:#{line}: #{text} can reach directory models by name; not allowed here"
          end
        end
      end
    end
  end

  def checker
    Rails.application.eager_load!
    directory_models = ApplicationRecord.descendants.map(&:name) - OWNED_MODELS
    Checker.new(directory_models)
  end

  test "module code never references directory models or bypasses DirectoryClient" do
    checker = self.checker
    files = MODULE_FILES.flat_map { |pattern| Dir[Rails.root.join(pattern)] }
    assert files.size > 5, "expected to find the module's files"

    violations = files.flat_map do |file|
      checker.violations(File.read(file), Pathname(file).relative_path_from(Rails.root).to_s)
    end

    assert_empty violations, "DataQuality must stay self-contained:\n#{violations.join("\n")}"
  end

  test "the checker catches each kind of violation" do
    code = <<~RUBY
      # Organization in a comment is fine
      Organization.find(1)
      ::Facility.where(name: "x")
      Directory::FactWriter.write
      candidate.subject
      "Evidence".constantize
      DataQuality::Organization # a module-local name is fine
      candidate.subject_id
    RUBY

    violations = checker.violations(code, "app/data_quality/example.rb")

    assert_equal 5, violations.size, violations.join("\n")
    assert_match "Organization", violations[0]
    assert_match "Facility", violations[1]
    assert_match "Directory::", violations[2]
    assert_match ".subject", violations[3]
    assert_match "constantize", violations[4]
    assert_empty checker.violations("Directory::Lookup.find_organization", DOOR)
  end
end
