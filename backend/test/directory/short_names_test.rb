require "test_helper"

# Short names (PM, 18 Oct 2026): a display label for tight spots, written
# through FactWriter and the seed loader, never used to find a record.
class Directory::ShortNamesTest < ActiveSupport::TestCase
  BY = "human:tosin"

  test "a short name is trimmed, optional and at most 30 characters, in the model and the database" do
    assert_equal "MEAG", Organization.create!(name: "MEAG Power", short_name: "  MEAG ").short_name
    assert_nil Organization.new(short_name: " ").short_name
    assert_not Organization.new(name: "A", short_name: "x" * 31).valid?
    assert_not Facility.new(name: "B", short_name: "x" * 31).valid?
    id = Organization.create!(name: "C").id
    assert_raises(ActiveRecord::StatementInvalid) { Organization.connection.execute("UPDATE organizations SET short_name = '' WHERE id = #{id}") }
  end

  test "FactWriter writes it on companies and plants" do
    company = Directory::FactWriter.write(:organization, { name: "Oglethorpe Power Corporation", short_name: "Oglethorpe" },
      verification: { status: "verified", by: BY })
    plant = Directory::FactWriter.write(:facility, { name: "Plant Vogtle", short_name: "Vogtle" }, verification: { status: "verified", by: BY })

    assert_equal "Oglethorpe", Organization.find(company.id).short_name
    assert_equal "Vogtle", Facility.find(plant.id).short_name
  end

  test "a seed sets a short name, and a later seed without one leaves it" do
    dir = Dir.mktmpdir("orgs")
    write_seed = ->(extra) { File.write(File.join(dir, "meag-power.yml"), { "name" => "MEAG Power", "status" => "active", **extra }.to_yaml) }
    write_seed.({ "short_name" => "MEAG" })
    Seed::OrganizationLoader.new(dir, facilities: nil).load!
    company = Organization.find_by!(slug: "meag-power")
    assert_equal "MEAG", company.short_name

    write_seed.({})
    Seed::OrganizationLoader.new(dir, facilities: nil).load!
    assert_equal "MEAG", company.reload.short_name, "a seed without one doesn't clear it"
  ensure
    FileUtils.rm_rf(dir)
  end

  test "a short name never finds a record" do
    Organization.create!(name: "U.S. Department of Energy", short_name: "DOE", verification_status: "verified", verified_by: BY)

    assert_nil Directory::Lookup.organization(name: "DOE"), "only names and aliases match"
    result = Directory::FactWriter.write(:organization, { name: "DOE" })
    assert result.created, "a source's \"DOE\" is a new name to review, not a match on the label"
  end
end
