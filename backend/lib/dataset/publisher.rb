# Publishes a dataset release draft to the data repo (#950), through the
# GitHub API only: a blob for each changed file, a tree on main's latest
# commit, the commit "Release YYYY.MM", main moved to it, the annotated tag
# vYYYY.MM, then the GitHub release "YYYY.MM". Zenodo archives the release
# by itself (its webhook on the repo) and mints the version DOI.
#
# Safe to run again: it refuses when the tag already exists at another
# commit, and after a partial failure it picks up at the step that failed
# (the commit is saved on the row as soon as it's made; the tag and the
# release are looked up before they're created).
#
# A dry run reads the repo and says what publishing would do, writing
# nothing to GitHub.
module Dataset
  class Publisher
    class Refused < StandardError; end
    # A second Publish of a release that's already out: nothing went wrong.
    class AlreadyPublished < Refused; end

    BRANCH = "main".freeze
    # Files a release owns. One the repo has that this release doesn't write
    # (a table held back) is deleted in the commit; any other file is left.
    TABLE_FILE = /\A(?:#{Export::TABLES.keys.join('|')})\.(?:csv|json)\z/

    def initialize(release, github: Github.new)
      @release = release
      @github = github
    end

    # Refusals before anything is read leave the release as it was; a failure
    # after marks it failed, with the reason, until it's published again.
    # built_at: the draft's build time when Publish was pressed. If the draft
    # was rebuilt since, its counts aren't the ones Data Quality signed off,
    # so it isn't published (Infra).
    def publish!(built_at: nil)
      raise AlreadyPublished, "v#{@release.version} is already published" if @release.published?
      if built_at && built_at != Publisher.stamp(@release.built_at)
        raise Refused, "v#{@release.version} was rebuilt after the page was loaded; check the new counts, then publish again"
      end

      raise Refused, "publishing isn't set up: DATASET_GITHUB_TOKEN is missing" unless @github.token?
      raise Refused, "v#{@release.version} has no files; rebuild it" unless @release.publishable?

      publish_steps
    end

    def publish_steps
      tagged = @github.tag_commit(@release.tag)
      if tagged && tagged != @release.commit_sha
        raise Refused, "#{@release.tag} already exists on GitHub at commit #{tagged.first(7)}, which isn't this release's"
      end

      unless tagged
        make_commit unless @release.commit_sha
        move_main(@github.branch_sha(BRANCH))
        @github.create_tag(@release.tag, sha: @release.commit_sha, message: "Release #{@release.version}")
      end
      found = @github.release(@release.tag) || @github.create_release(tag: @release.tag, name: @release.version, body: release_body)
      @release.update!(status: "published", published_at: Time.current, release_url: found["html_url"], error: nil)
      @release
    rescue Refused, Github::Error => e
      @release.update!(status: "failed", error: e.message)
      raise
    end
    private :publish_steps

    # What publishing would do, from the repo as it is now: only the steps
    # left, after a partial publish too (Copilot). Saved on the row.
    def dry_run
      head = @github.branch_sha(BRANCH)
      tagged = @github.tag_commit(@release.tag)
      steps, blocked = remaining(head, tagged)
      diff = if steps.include?("commit")
        changes(@github.tree_files(@github.commit(head).dig("tree", "sha")))
      else
        { added: [], changed: [], removed: [] }
      end
      blocked ||= "DATASET_GITHUB_TOKEN is missing" unless @github.token?
      result = { "checked_at" => Time.current.iso8601, "main" => head, "commit" => @release.commit_sha, "steps" => steps,
        "added" => diff[:added], "changed" => diff[:changed], "removed" => diff[:removed],
        "unchanged" => @release.files.size - diff[:added].size - diff[:changed].size, "commit_message" => "Release #{@release.version}",
        "tag" => @release.tag, "release_name" => @release.version, "release_body" => release_body, "blocked" => blocked }
      @release.update!(dry_run: result)
      result
    end

    # A build time as the Publish form sends it, to the microsecond.
    def self.stamp(time) = time&.utc&.iso8601(6)

    def release_body
      counts = @release.ordered_counts.map { |table, count| "#{ActiveSupport::NumberHelper.number_to_delimited(count)} #{NOUNS.fetch(table, table)}" }
      compared = @release.previous_version ? " See CHANGELOG.md for what changed since #{@release.previous_version}." : ""
      "Version #{@release.version} of the Nuclear Directory dataset: every published fact, with the public document each comes from. " \
        "#{counts.to_sentence}, each table as CSV and JSON.#{compared} See README.md for the fields and how to cite it. Licence: CC BY 4.0."
    end

    NOUNS = { "companies" => "companies", "facilities" => "facilities (sites and reactor units)", "relationships" => "relationships",
      "deal_terms" => "deal terms", "licensing_stages" => "licensing stages", "sources" => "sources", "evidence" => "evidence rows" }.freeze

    STEPS = %w[commit move_main tag release].freeze

    private
      # [steps left, why publishing would stop (or nil)], as publish! would go.
      def remaining(head, tagged)
        return [ [], "it's already published" ] if @release.published?
        return [ [], "#{@release.tag} already exists at commit #{tagged.first(7)}, which isn't this release's" ] if tagged && tagged != @release.commit_sha
        return [ @github.release(@release.tag) ? [] : %w[release], nil ] if tagged
        return [ STEPS, nil ] unless @release.commit_sha

        case main_against(head)
        when :there then [ %w[tag release], nil ]
        when :ahead then [ %w[move_main tag release], nil ]
        else [ [], "main moved on since commit #{@release.commit_sha.first(7)}; the next Publish drops it and stops, and the one after commits on top" ]
        end
      end

      # Where main stands against the saved release commit: :there (main has
      # it), :ahead (main can move forward to it) or :diverged.
      def main_against(head)
        return :there if head == @release.commit_sha

        case @github.compare(head, @release.commit_sha)
        when "ahead" then :ahead
        when "behind", "identical" then :there
        else :diverged
        end
      end

      def changes(current)
        files = @release.files.to_a
        { added: files.reject { |file| current.key?(file.path) }.map(&:path),
          changed: files.select { |file| current.key?(file.path) && current[file.path] != file.git_sha }.map(&:path),
          removed: current.keys.grep(TABLE_FILE) - files.map(&:path) }
      end

      def make_commit
        head = @github.branch_sha(BRANCH)
        base = @github.commit(head).dig("tree", "sha")
        diff = changes(@github.tree_files(base))
        writes = @release.files.select { |file| diff[:added].include?(file.path) || diff[:changed].include?(file.path) }
        entries = writes.map { |file| { path: file.path, mode: "100644", type: "blob", sha: @github.create_blob(file.content) } } +
          diff[:removed].map { |path| { path:, mode: "100644", type: "blob", sha: nil } }
        tree = @github.create_tree(base_tree: base, entries:)
        @release.update!(commit_sha: @github.create_commit(message: "Release #{@release.version}", tree:, parent: head))
      end

      # main to the release commit, unless main already has it. If main moved
      # on another way since the commit was made, the commit is dropped so the
      # next run makes a new one on top (no tag points at it yet).
      def move_main(head)
        case main_against(head)
        when :there then nil
        when :ahead then @github.move_branch(BRANCH, @release.commit_sha)
        else drop_commit!
        end
      rescue Github::Error => e
        raise unless e.status == 422

        drop_commit!
      end

      def drop_commit!
        @release.update!(commit_sha: nil)
        raise Refused, "main moved on since the release commit was made; publish again to commit on top of it"
      end
  end
end
