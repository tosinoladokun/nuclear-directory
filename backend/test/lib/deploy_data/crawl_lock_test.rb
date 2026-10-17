require "test_helper"

class DeployData::CrawlLockTest < ActiveSupport::TestCase
  # Names of its own, so a pipeline test running in parallel can't hold them.
  NAMES = [ "deploy_data_test:a", "deploy_data_test:b" ].freeze

  test "covers the shared lock and every source kind's pipeline lock" do
    names = DeployData::CrawlLock.names
    assert_includes names, "data_quality:writes"
    assert_includes names, "data_quality:nrc_reactor_list"
    assert_includes names, "data_quality:eia_generators"
  end

  test "holds every lock, or none while another session holds one" do
    assert DeployData::CrawlLock.hold(names: NAMES) { }

    # A session of its own: the test's pool hands every thread one connection.
    other = PG.connect(**ActiveRecord::Base.connection.raw_connection.conninfo_hash.compact.slice(:host, :port, :dbname, :user, :password))
    begin
      other.exec("SELECT pg_advisory_lock(#{Zlib.crc32(NAMES.last)})")
      ran = false
      refute DeployData::CrawlLock.hold(names: NAMES) { ran = true }
      refute ran
      # The first lock it took was given back.
      assert_equal "t", other.exec("SELECT pg_try_advisory_lock(#{Zlib.crc32(NAMES.first)})").getvalue(0, 0)
    ensure
      other.close
    end
  end
end
