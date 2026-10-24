require "test_helper"

# EIA's utility ID (#382): a company identity key from EIA-860, matched
# before any name, as the SEC's CIK is.
class Directory::EiaUtilityIdTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @source = sources(:press_release)
    @company = Organization.create!(name: "Georgia Power", verification_status: "verified", verified_by: BY)
    # Names are found through aliases, so its own name is one: a name lookup
    # really finds it, and the ID tests below are a real conflict.
    @company.aliases.create!(alias: "Georgia Power")
  end

  test "a utility ID is a plain number, stored without leading zeros, and unique" do
    assert_equal "7140", Organization.create!(name: "A", eia_utility_id: " 07140 ").eia_utility_id
    assert_nil Organization.new(eia_utility_id: "").eia_utility_id
    assert_not Organization.new(name: "B", eia_utility_id: "71-40").valid?
    assert_not Organization.new(name: "C", eia_utility_id: "7140").valid?, "taken"
    id = Organization.create!(name: "D").id
    error = assert_raises(ActiveRecord::StatementInvalid) do
      Organization.connection.execute("UPDATE organizations SET eia_utility_id = '0' WHERE id = #{id}")
    end
    assert_match "organizations_eia_utility_id_check", error.message
  end

  test "match finds a company by its utility ID before its name" do
    by_id = Organization.create!(name: "Georgia Power Holdings", eia_utility_id: "7140", verification_status: "verified", verified_by: BY)
    found = DataQuality::Stages::Match.new(plugin: nil).send(:resolve_organization, { "name" => "Georgia Power", "eia_utility_id" => "7140" })

    assert_equal [ by_id.id, "EIA utility ID" ], [ found.record.id, found.by ], "the name would have found the other company"
  end

  test "a link's company end is found by its utility ID first" do
    by_id = Organization.create!(name: "Georgia Power Holdings", eia_utility_id: "7140", verification_status: "verified", verified_by: BY)
    ends = ->(named) { DataQuality::DirectoryClient.new.send(:link_end_ids, { "organization" => named })[:organization_id] }

    assert_equal by_id.id, ends.({ "eia_utility_id" => "7140", "name" => "Georgia Power" })
  end

  test "FactWriter finds a company by its utility ID before its name" do
    @company.update!(eia_utility_id: "7140")
    result = Directory::FactWriter.write(:organization, { name: "Georgia Power Co", eia_utility_id: "7140" },
      evidence: [ { source_id: @source.id, quote: "Georgia Power Co", found_by: "crawler" } ], protect_human_verified: true)

    assert_equal @company.id, result.id, "EIA's spelling differs; the ID finds it"
    assert_equal @company.id, Directory::Lookup.organization(eia_utility_id: "7140").id
  end

  test "a seed sets the utility ID, and a later seed without one leaves it" do
    @company.destroy!
    dir = Dir.mktmpdir("orgs")
    write_seed = ->(extra) { File.write(File.join(dir, "georgia-power.yml"), { "name" => "Georgia Power", "status" => "active", **extra }.to_yaml) }
    write_seed.({ "eia_utility_id" => 7140 })
    Seed::OrganizationLoader.new(dir, facilities: nil).load!
    company = Organization.find_by!(slug: "georgia-power")
    assert_equal "7140", company.eia_utility_id

    write_seed.({})
    Seed::OrganizationLoader.new(dir, facilities: nil).load!
    assert_equal "7140", company.reload.eia_utility_id, "a seed without one doesn't clear it"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "a merge moves the duplicate's utility ID, and the preview says so" do
    duplicate = Organization.create!(name: "Georgia Power Co", eia_utility_id: "7140", verification_status: "verified", verified_by: BY)

    _, preview = Directory::FactWriter.merge_preview(type: "Organization", from_id: duplicate.id, into_id: @company.id)
    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @company.id, by: BY).ok?

    assert_equal "7140", @company.reload.eia_utility_id
    assert_nil duplicate.reload.eia_utility_id
    assert_match "1 EIA utility ID", preview
  end
end
