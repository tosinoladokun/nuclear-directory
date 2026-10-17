require "test_helper"

# Outside a test transaction, so the data step's own transaction is the
# outermost one and gets its repeatable-read snapshot, as in production.
class DeployData::IsolationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class FakeBackup
    def take! = "backup-2026-10-17T0300Z-predeploy"
  end

  class FakeGitHub
    attr_reader :posts

    def initialize = @posts = []
    def pull_request_for(_commit) = nil
    def post(body, **) = (@posts << body; nil)
  end

  class FakeLock
    def hold = (yield; true)
  end

  setup do
    @root = Pathname(Dir.mktmpdir)
    FileUtils.mkdir_p(@root.join("db/seeds/organizations"))
    File.write(@root.join("db/seeds/organizations/westinghouse.yml"), "name: Westinghouse\n")
    FileUtils.mkdir_p(@root.join("db/data"))
    @organization = Organization.create!(name: "Isolation Test Co", slug: "isolation-test-co", verification_status: "pending")
  end

  teardown do
    FileUtils.rm_rf(@root)
    connection = ActiveRecord::Base.connection
    connection.execute("DELETE FROM verification_events WHERE subject_type = 'Organization' AND subject_id = #{@organization.id}")
    connection.execute("DELETE FROM organizations WHERE id = #{@organization.id}")
    connection.execute("DELETE FROM data_deploys")
  end

  test "an approval another session commits mid-run isn't counted as the seed's" do
    other = PG.connect(**ActiveRecord::Base.connection.raw_connection.conninfo_hash.compact.slice(:host, :port, :dbname, :user, :password))
    concurrent_approval = lambda do
      other.exec("INSERT INTO verification_events (subject_type, subject_id, to_status, by, created_at) " \
        "VALUES ('Organization', #{@organization.id}, 'verified', 'human:tosin', now())")
    end
    github = FakeGitHub.new
    run = DeployData::Run.new(commit: "abc1234def", mode: "on", backup: FakeBackup.new, github:, lock: FakeLock.new, root: @root,
      migrations: DeployData::Migrations.new(@root.join("db/data")), seeder: concurrent_approval, checker: -> { [] })

    status = nil
    capture_io { status = run.call }
    assert_equal :applied, status
    assert_includes github.posts.sole, "Verification events written by the seed: 0"
  ensure
    other&.close
  end
end
