require "test_helper"

class DeployData::BackupTest < ActiveSupport::TestCase
  Status = Data.define(:exitstatus) { def success? = exitstatus.zero? }

  def take_with(output, exitstatus)
    Open3.stub_capture2e = [ output, Status.new(exitstatus) ]
    capture_io { return DeployData::Backup.take! }
  end

  setup do
    Open3.singleton_class.prepend(Module.new do
      attr_accessor :stub_capture2e

      def capture2e(*args, **kwargs) = stub_capture2e || super
    end) unless Open3.respond_to?(:stub_capture2e)
  end

  teardown { Open3.stub_capture2e = nil }

  test "a published backup counts even if pruning failed after it" do
    output = "Wrote x.dump.age (1M)\nUploaded to o/r release backup-2026-10-17T0300Z-predeploy\n"
    assert_equal "backup-2026-10-17T0300Z-predeploy", take_with(output, 22)
  end

  test "no published backup is a failure" do
    assert_raises(DeployData::Backup::Failed) { take_with("Wrote x.dump.age (1M)\n", 22) }
  end
end
