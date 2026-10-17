require "test_helper"

class DeployData::FingerprintTest < ActiveSupport::TestCase
  test "the seed's files and the code that writes them, each with its own hash" do
    paths = DeployData::Fingerprint.current.files.keys
    assert_includes paths, "db/seeds.rb"
    assert_includes paths, "db/seeds/facilities.yml"
    assert_includes paths, "lib/seed/organization_loader.rb"
    assert_includes paths, "app/directory/fact_writer.rb"
    assert(paths.any? { |path| path.start_with?("db/seeds/organizations/") })
  end

  test "lists files added, changed and removed" do
    before = DeployData::Fingerprint.new("a.yml" => "1", "b.yml" => "2", "c.yml" => "3")
    after = DeployData::Fingerprint.new("a.yml" => "1", "b.yml" => "9", "d.yml" => "4")
    assert_equal %w[b.yml c.yml d.yml], after.changed_since(before.files)
    assert_equal %w[a.yml b.yml c.yml], before.changed_since(nil)
    refute_equal before.digest, after.digest
    assert_equal before.digest, DeployData::Fingerprint.new("c.yml" => "3", "a.yml" => "1", "b.yml" => "2").digest
  end
end
