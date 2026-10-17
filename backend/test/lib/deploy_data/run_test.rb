require "test_helper"

class DeployData::RunTest < ActiveSupport::TestCase
  # Stand-ins for the backup, GitHub and the crawl's lock.
  class FakeBackup
    attr_reader :taken

    def initialize(fail: false) = (@fail = fail; @taken = 0)

    def take!
      raise DeployData::Backup::Failed, "the backup didn't finish (exit 1)" if @fail

      @taken += 1
      "backup-2026-10-17T0300Z-predeploy"
    end
  end

  class FakeGitHub
    attr_reader :posts

    def initialize = @posts = []
    def pull_request_for(_commit) = 298
    def post(body, pull_request:, title:) = (@posts << { body:, pull_request:, title: }; "https://github.com/x/y/pull/298#c")
  end

  class FakeLock
    def initialize(free: true) = @free = free
    def hold = (@free ? (yield; true) : false)
  end

  setup do
    @root = Pathname(Dir.mktmpdir)
    write "db/seeds/organizations/westinghouse.yml", "name: Westinghouse\n"
    write "db/seeds/organizations/terrapower.yml", "name: TerraPower\n"
    FileUtils.mkdir_p(@root.join("db/data"))
    @backup = FakeBackup.new
    @github = FakeGitHub.new
    @seeds = 0
    @seeder = -> { @seeds += 1 }
    @collisions = []
  end

  teardown { FileUtils.rm_rf(@root) }

  def write(path, content)
    FileUtils.mkdir_p(@root.join(path).dirname)
    File.write(@root.join(path), content)
  end

  def run_step(dry_run: false, mode: "on", lock: FakeLock.new, backup: @backup, seeder: @seeder)
    run = DeployData::Run.new(dry_run:, commit: "abc1234def", mode:, backup:, github: @github, lock:, root: @root,
      migrations: DeployData::Migrations.new(@root.join("db/data")), seeder:, checker: -> { @collisions })
    status = nil
    @output = capture_io { status = run.call }.first
    status
  end

  test "off unless AUTO_DATA_DEPLOY is on or report: no backup, no seed, no record" do
    assert_equal :disabled, run_step(mode: nil)
    assert_equal :disabled, run_step(mode: "yes")
    assert_equal 0, @backup.taken
    assert_equal 0, @seeds
    assert_equal 0, DataDeploy.count
    assert_includes @output, "AUTO_DATA_DEPLOY"
  end

  test "first run: backup, seed:check, seed, a record, and a report on the PR" do
    assert_equal :applied, run_step

    assert_equal 1, @backup.taken
    assert_equal 1, @seeds
    deploy = DataDeploy.sole
    assert deploy.applied?
    assert_equal "backup-2026-10-17T0300Z-predeploy", deploy.backup_tag
    assert_equal DeployData::Fingerprint.current(@root).digest, deploy.seed_digest
    assert_equal 298, @github.posts.sole[:pull_request]
    report = @github.posts.sole[:body]
    assert_includes report, "Data deploy abc1234 (PR #298): applied"
    assert_includes report, "seed:check: no collisions"
    assert_includes report, "Seed: ran (first automatic run)"
    assert_includes report, "Public totals, before -> after:"
    assert_includes report, "  companies"
  end

  test "nothing to do when the seed hasn't changed and no data migration is new" do
    run_step
    assert_equal :nothing, run_step
    assert_equal 1, @seeds
    assert_equal 1, @backup.taken
    assert_equal 1, DataDeploy.count
  end

  test "a changed loader file re-runs the seed, like a changed seed file" do
    run_step
    write "lib/seed/organization_loader.rb", "# changed\n"
    assert_equal :applied, run_step
    assert_equal 2, @seeds
    assert_includes @github.posts.last[:body], "Seed: ran (1 file changed since abc1234)"
  end

  test "flags events written for records whose files didn't change" do
    run_step
    write "db/seeds/organizations/terrapower.yml", "name: TerraPower Inc\n"
    westinghouse = organizations(:westinghouse)
    terrapower = organizations(:terrapower)
    seeder = lambda do
      VerificationEvent.create!(subject: terrapower, to_status: "verified", by: "human:tosin")
      VerificationEvent.create!(subject: westinghouse, to_status: "verified", by: "human:tosin")
    end

    assert_equal :applied, run_step(seeder:)
    report = @github.posts.last[:body]
    assert_includes report, "**Needs a look:**"
    assert_includes report, "Verification events written by the seed: 2"
    assert_includes report, "Flag: events for records whose files didn't change (1):"
    assert_includes report, "Organization #{westinghouse.id} (westinghouse): 1 event"
    refute_includes report, "(terrapower)"
  end

  test "a collision stops it before any write" do
    @collisions = [ "terrapower: \"TerraPower\" already belongs to Other (other)" ]
    assert_equal :stopped, run_step

    assert_equal 0, @seeds
    assert DataDeploy.sole.stopped?
    report = @github.posts.sole[:body]
    assert_includes report, "stopped: seed:check found collisions, so nothing was written"
    assert_includes report, "Note: terrapower: \"TerraPower\" already belongs to Other (other)"
    assert_equal :applied, (@collisions = []; run_step), "the next deploy tries again"
  end

  test "a failed backup stops it before any write" do
    assert_equal :stopped, run_step(backup: FakeBackup.new(fail: true))
    assert_equal 0, @seeds
    assert_includes @github.posts.sole[:body], "stopped: the backup didn't finish (exit 1), so nothing was written"
  end

  test "stops while the daily crawl holds its lock" do
    assert_equal :stopped, run_step(lock: FakeLock.new(free: false))
    assert_equal 0, @backup.taken
    assert_equal 0, @seeds
    assert_includes @github.posts.sole[:body], "the daily crawl is running"
  end

  test "a seed that fails writes nothing and is recorded as failed" do
    seeder = -> { Organization.create!(name: "Half Written", slug: "half-written"); raise Seed::OrganizationLoader::Error, "Seed failed, nothing was written" }
    assert_equal :failed, run_step(seeder:)

    refute Organization.exists?(slug: "half-written")
    deploy = DataDeploy.sole
    assert deploy.failed?
    assert_includes deploy.error, "Seed failed"
    assert_includes @github.posts.sole[:body], "failed: Error: Seed failed, nothing was written"
    assert_equal :applied, run_step, "the next deploy tries again"
  end

  test "a dry run rolls everything back and posts nothing" do
    seeder = -> { Organization.create!(name: "Rehearsed", slug: "rehearsed") }
    assert_equal :reported, run_step(dry_run: true, mode: nil, seeder:)

    refute Organization.exists?(slug: "rehearsed")
    assert_equal 0, @backup.taken
    assert_equal 0, DataDeploy.count
    assert_empty @github.posts
    assert_includes @output, "Dry run (rolled back) abc1234 (PR #298): would apply"
    assert_includes @output, "Backup: skipped (dry run)"
    assert_match(/organizations\s+\d+ -> \d+  \(\+1\)/, @output)
  end

  test "runs a new data migration once, as the human who approved it" do
    run_step
    write "db/data/20261017120000_rename_westinghouse.rb", <<~RUBY
      class RenameWestinghouse < DeployData::Migration
        BY = "human:tosin"

        def up
          Organization.find_by!(slug: "westinghouse").update!(name: "Westinghouse Electric")
          say "renamed westinghouse (\#{reason})"
        end
      end
    RUBY

    assert_equal :applied, run_step
    assert_equal "Westinghouse Electric", organizations(:westinghouse).reload.name
    assert_equal 1, @seeds, "the seed didn't change, so it didn't run"
    ran = DataMigration.sole
    assert_equal [ "20261017120000", "rename_westinghouse", "human:tosin" ], [ ran.version, ran.name, ran.by ]
    assert_equal "deploy abc1234, PR #298", ran.reason
    report = @github.posts.last[:body]
    assert_includes report, "Seed: skipped (unchanged since abc1234)"
    assert_includes report, "  20261017120000 rename_westinghouse (by human:tosin)"
    assert_includes report, "    renamed westinghouse (deploy abc1234, PR #298)"

    assert_equal :nothing, run_step
  end

  test "a failing data migration is rolled back and runs again next time" do
    run_step
    write "db/data/20261017120000_breaks.rb", <<~RUBY
      class Breaks < DeployData::Migration
        BY = "human:tosin"

        def up
          Organization.find_by!(slug: "westinghouse").update!(name: "Changed")
          raise "the pinned quote is gone"
        end
      end
    RUBY

    assert_equal :failed, run_step
    assert_equal "Westinghouse Electric Company", organizations(:westinghouse).reload.name
    assert_equal 0, DataMigration.count
    assert_includes @github.posts.last[:body], "failed: MigrationFailed: data migration 20261017120000 breaks: RuntimeError: the pinned quote is gone"
  end

  test "a data migration must name a human as BY" do
    run_step
    write "db/data/20261017120000_by_deploy.rb", <<~RUBY
      class ByDeploy < DeployData::Migration
        BY = "deploy:abc1234"
        def up = Organization.find_by!(slug: "westinghouse").update!(name: "Changed")
      end
    RUBY

    assert_equal :failed, run_step
    assert_equal "Westinghouse Electric Company", organizations(:westinghouse).reload.name
    assert_includes @github.posts.last[:body], "BY must name the human who approved it"
  end

  test "report mode: a real backup, the seed and data migrations rolled back, and the would-be report on the PR" do
    write "db/data/20261017120000_rename_westinghouse.rb", <<~RUBY
      class RenameWestinghouse < DeployData::Migration
        BY = "human:tosin"
        def up = Organization.find_by!(slug: "westinghouse").update!(name: "Westinghouse Electric")
      end
    RUBY
    seeder = -> { Organization.create!(name: "Rehearsed", slug: "rehearsed") }

    assert_equal :reported, run_step(mode: "report", seeder:)
    refute Organization.exists?(slug: "rehearsed")
    assert_equal "Westinghouse Electric Company", organizations(:westinghouse).reload.name
    assert_equal 0, DataMigration.count
    assert_equal 1, @backup.taken, "the backup is real"
    assert DataDeploy.sole.reported?
    report = @github.posts.sole[:body]
    assert_includes report, "Report mode (rolled back; apply by hand) abc1234 (PR #298): would apply"
    assert_includes report, "  20261017120000 rename_westinghouse (by human:tosin)"

    assert_equal :nothing, run_step(mode: "report"), "it doesn't report the same seed and migration again"
    assert_equal :applied, run_step(mode: "on"), "switched on, it applies what report mode only rehearsed"
    assert_equal "Westinghouse Electric", organizations(:westinghouse).reload.name
  end

  test "the loader's per-kind counts go in the report" do
    seeder = -> { puts format("%-24s %3d created, %3d updated", "organization", 2, 68) }
    run_step(seeder:)
    report = @github.posts.sole[:body]
    assert_includes report, "Seed counts, from the loader:"
    assert_match(/  organization\s+2 created, 68 updated/, report)
    assert_includes @output, "organization", "still printed to the deploy log"
  end

  test "if a later data migration fails, the seed and earlier migrations are rolled back too" do
    run_step
    write "db/seeds/organizations/terrapower.yml", "name: TerraPower Inc\n"
    write "db/data/20261017120000_fix_after_seed.rb", <<~RUBY
      class FixAfterSeed < DeployData::Migration
        BY = "human:tosin"
        def up = Organization.find_by!(slug: "westinghouse").update!(name: "Fixed")
      end
    RUBY
    write "db/data/20261017130000_breaks.rb", <<~RUBY
      class Breaks < DeployData::Migration
        BY = "human:tosin"
        def up = raise("the pinned quote is gone")
      end
    RUBY
    seeder = -> { Organization.find_by!(slug: "westinghouse").update!(name: "Seeded") }

    assert_equal :failed, run_step(seeder:)
    assert_equal "Westinghouse Electric Company", organizations(:westinghouse).reload.name
    assert_equal 0, DataMigration.count

    File.delete(@root.join("db/data/20261017130000_breaks.rb"))
    assert_equal :applied, run_step(seeder:), "the next deploy runs the seed and both fixes again"
    assert_equal "Fixed", organizations(:westinghouse).reload.name, "the fix lands after the re-seed"
  end

  test "a data migration that won't load or has no up is reported, not missed" do
    run_step
    write "db/data/20261017120000_no_up.rb", <<~RUBY
      class NoUp < DeployData::Migration
        BY = "human:tosin"
      end
    RUBY
    assert_equal :failed, run_step
    assert_includes @github.posts.last[:body], "NotImplementedError"

    File.delete(@root.join("db/data/20261017120000_no_up.rb"))
    write "db/data/20261017120000_broken.rb", "class Broken < DeployData::Migration\n  def up(\nend\n"
    assert_equal :failed, run_step
    assert_includes @github.posts.last[:body], "SyntaxError"
    assert_equal 2, DataDeploy.failed.count
  end

  test "if the applied record can't be saved, the data it describes is rolled back too" do
    run_step
    write "db/seeds/organizations/terrapower.yml", "name: TerraPower Inc\n"
    write "db/data/20261017120000_fix.rb", <<~RUBY
      class Fix < DeployData::Migration
        BY = "human:tosin"
        def up = Organization.find_by!(slug: "westinghouse").update!(name: "Fixed")
      end
    RUBY

    # The applied record's insert fails; the failed run's own record still saves.
    DataDeploy.singleton_class.prepend(Module.new do
      def create!(**attributes)
        raise ActiveRecord::StatementInvalid, "disk full" if attributes[:status] == :applied && Thread.current[:fail_applied]

        super
      end
    end)
    Thread.current[:fail_applied] = true
    begin
      assert_equal :failed, run_step
    ensure
      Thread.current[:fail_applied] = nil
    end
    assert_equal "Westinghouse Electric Company", organizations(:westinghouse).reload.name
    assert_equal 0, DataMigration.count
    assert_equal :applied, run_step, "the next deploy runs it all again"
    assert_equal "Fixed", organizations(:westinghouse).reload.name
  end

  test "a seed error's details go in the report, not just its first line" do
    seeder = -> { raise Seed::OrganizationLoader::Error, "Seed failed, nothing was written:\n  organization \"X\": name can't be blank" }
    assert_equal :failed, run_step(seeder:)
    report = @github.posts.sole[:body]
    assert_includes report, "failed: Error: Seed failed, nothing was written:"
    assert_includes report, "Note: organization \"X\": name can't be blank"
  end

  test "a timeout during the GitHub lookup stops the run before the backup" do
    github = DeployData::GitHub.new(token: "test-token")
    stub_request(:get, %r{api.github.com/repos/.+/commits/.+/pulls}).to_raise(DeployData::Run::TimedOut.new("took longer than bin/deploy-data allows"))
    stub_request(:post, %r{api.github.com/repos/.+/issues}).to_return(status: 201, body: { html_url: "https://github.com/x" }.to_json)
    run = DeployData::Run.new(commit: "abc1234def", mode: "on", backup: @backup, github:, lock: FakeLock.new, root: @root,
      migrations: DeployData::Migrations.new(@root.join("db/data")), seeder: @seeder, checker: -> { [] })

    status = nil
    capture_io { status = run.call }
    assert_equal :failed, status
    assert_equal 0, @backup.taken
    assert_equal 0, @seeds
    assert_includes DataDeploy.sole.error, "TimedOut"
  end

  test "a timeout while posting the report doesn't change what was applied" do
    github = DeployData::GitHub.new(token: "test-token")
    stub_request(:get, %r{api.github.com/repos/.+/commits/.+/pulls}).to_return(status: 200, body: [ { number: 298, merged_at: "2026-10-17T00:00:00Z" } ].to_json)
    stub_request(:post, %r{api.github.com/repos/.+/issues/298/comments}).to_raise(DeployData::Run::TimedOut.new("took longer than bin/deploy-data allows"))
    run = DeployData::Run.new(commit: "abc1234def", mode: "on", backup: @backup, github:, lock: FakeLock.new, root: @root,
      migrations: DeployData::Migrations.new(@root.join("db/data")), seeder: @seeder, checker: -> { [] })

    status = nil
    _, err = capture_io { status = run.call }
    assert_equal :applied, status
    assert DataDeploy.sole.applied?
    assert_includes err, "couldn't post the report to GitHub"
  end

  class LockThatTimesOutOnRelease
    def hold
      yield
      raise DeployData::Run::TimedOut, "took longer than bin/deploy-data allows"
    end
  end

  test "a timeout while releasing the locks, after the commit, keeps the outcome applied" do
    assert_equal :applied, run_step(lock: LockThatTimesOutOnRelease.new)
    assert DataDeploy.sole.applied?
    report = @github.posts.sole[:body]
    assert_includes report, "Data deploy abc1234 (PR #298): applied"
    assert_includes report, "Error after the data committed (it stands): TimedOut"
    assert_includes report, "**Needs a look:**"
    assert_equal :nothing, run_step, "the next deploy doesn't repeat it"
  end

  test "an after-commit callback that raises keeps the outcome applied" do
    seeder = -> { ActiveRecord::Base.current_transaction.after_commit { raise "snapshot expiry failed" } }
    assert_equal :applied, run_step(seeder:)
    assert DataDeploy.sole.applied?
    assert_includes @github.posts.sole[:body], "Error after the data committed (it stands): RuntimeError: snapshot expiry failed"
  end

  test "report mode compares flip-flops with the last applied run, not the last report" do
    run_step
    westinghouse = organizations(:westinghouse)
    write "db/seeds/organizations/westinghouse.yml", "name: Westinghouse Electric\n"
    assert_equal :reported, run_step(mode: "report", seeder: -> { VerificationEvent.create!(subject: westinghouse, to_status: "verified", by: "human:tosin") })

    # The next PR changes another file. Westinghouse's change is still
    # pending (the report rolled back), so writing it again isn't a flip-flop.
    write "db/seeds/organizations/terrapower.yml", "name: TerraPower Inc\n"
    seeder = lambda do
      VerificationEvent.create!(subject: westinghouse, to_status: "verified", by: "human:tosin")
      VerificationEvent.create!(subject: organizations(:terrapower), to_status: "verified", by: "human:tosin")
    end
    assert_equal :reported, run_step(mode: "report", seeder:)
    refute_includes @github.posts.last[:body], "Flag:"
  end
end
