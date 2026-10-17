require "digest"

module DeployData
  # What a re-seed depends on: the seed files and the code that writes them
  # (a loader change can change what the seed writes with no YAML change).
  # Paths are relative to the app root.
  class Fingerprint
    PATTERNS = %w[db/seeds.rb db/seeds/**/*.yml lib/seed/**/*.rb app/directory/fact_writer.rb].freeze
    # Files whose change can alter what's written for every record.
    CODE = %r{\A(db/seeds\.rb|lib/seed/|app/directory/fact_writer\.rb)}

    attr_reader :files

    def self.current(root = Rails.root)
      paths = PATTERNS.flat_map { |pattern| Dir.glob(pattern, base: root.to_s) }.uniq.sort
      new(paths.to_h { |path| [ path, Digest::SHA256.file(File.join(root.to_s, path)).hexdigest ] })
    end

    # files: { path => sha256 }
    def initialize(files)
      @files = files.to_h.sort.to_h
    end

    def digest = Digest::SHA256.hexdigest(files.map { |path, sha| "#{sha}  #{path}\n" }.join)

    # Paths added, changed or removed since the earlier file list.
    def changed_since(earlier)
      earlier = earlier.to_h
      (files.keys | earlier.keys).reject { |path| files[path] == earlier[path] }.sort
    end

    def self.code_changed?(paths) = paths.any? { |path| path.match?(CODE) }
  end
end
