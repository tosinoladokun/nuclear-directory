require "tmpdir"

# Builds this month's dataset release from production into a draft (#950):
# the previous release's manifest and changelog come from the data repo's
# newest tag, Export writes every file into a temporary folder, and the files
# are stored, gzipped, on the release row. The folder is removed after.
#
# A rebuild replaces the draft. It never touches a published release, or one
# whose publishing has already made a commit.
#
#   Dataset::Draft.build!(version: "2026.12")
module Dataset
  class Draft
    class Refused < StandardError; end

    def self.build!(version: Date.current.strftime("%Y.%m"), github: Github.new, tables: DatasetRelease.tables_setting)
      new(version:, github:, tables:).build!
    end

    def initialize(version:, github:, tables:)
      @version = version
      @github = github
      @tables = tables
    end

    def build!
      release = DatasetRelease.find_or_initialize_by(version: @version)
      refuse!(release)
      previous_tag = @github.latest_tag
      raise Refused, "v#{@version} is already released on GitHub" if previous_tag == "v#{@version}"

      Dir.mktmpdir("dataset-#{@version}") do |tmp|
        previous = previous_tag && fetch_previous(previous_tag, File.join(tmp, "previous"))
        out = File.join(tmp, "release")
        result = Export.new(out, version: @version, previous:, tables: @tables).write!
        files = Dir.glob("**/*", File::FNM_DOTMATCH, base: out).sort.select { |path| File.file?(File.join(out, path)) }
          .map { |path| DatasetReleaseFile.build_from(path, File.binread(File.join(out, path))) }
        manifest = previous && JSON.parse(File.read(File.join(previous, "manifest.json")))

        DatasetRelease.transaction do
          release.lock! if release.persisted?
          refuse!(release)
          release.files.delete_all if release.persisted?
          release.update!(status: "draft", tables_included: @tables, counts: result[:counts], unknown_publishers: result[:unknown_publishers],
            previous_version: manifest&.fetch("version"), previous_counts: manifest&.fetch("counts"),
            changelog: File.read(File.join(out, "CHANGELOG.md")), built_at: Time.current, error: nil, dry_run: nil)
          files.each { |file| file.release = release }.each(&:save!)
        end
      end
      release
    end

    private
      def refuse!(release)
        raise Refused, "v#{@version} is published; it can't be rebuilt" if release.published?
        raise Refused, "publishing v#{@version} has started (commit #{release.commit_sha.first(7)}); publish it again to finish" unless release.rebuildable?
      end

      # The previous release's manifest.json and CHANGELOG.md, as Export reads them.
      def fetch_previous(tag, dir)
        manifest = @github.file("manifest.json", ref: tag) or raise Refused, "#{tag} has no manifest.json"
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "manifest.json"), manifest)
        changelog = @github.file("CHANGELOG.md", ref: tag)
        File.write(File.join(dir, "CHANGELOG.md"), changelog) if changelog
        dir
      end
  end
end
