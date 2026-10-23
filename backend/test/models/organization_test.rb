require "test_helper"

class OrganizationTest < ActiveSupport::TestCase
  test "slug comes from the name" do
    assert_equal "kairos-power", Organization.create!(name: "Kairos Power").slug
  end

  test "slug is unique" do
    org = Organization.new(name: "Westinghouse", slug: organizations(:westinghouse).slug)
    assert_not org.valid?
    assert_includes org.errors[:slug], "has already been taken"
  end

  # #154: Facility opts into suffixing because an EIA site and an NRC unit
  # can share a name; organizations shouldn't quietly save as "name-2". The
  # :westinghouse fixture already holds the slug "westinghouse".
  test "a duplicate organization name doesn't auto-suffix the slug" do
    dup = Organization.new(name: "Westinghouse")
    assert_not dup.valid?
    assert_equal "westinghouse", dup.slug
    assert_includes dup.errors[:slug], "has already been taken"
  end

  test "domain is normalized and unique" do
    org = Organization.new(name: "Copycat", domain: " WWW.TerraPower.com ")
    assert_equal "terrapower.com", org.domain
    assert_not org.valid?
    assert_includes org.errors[:domain], "has already been taken"
  end

  test "many organizations can have no domain" do
    Organization.create!(name: "No Domain A", domain: "")
    assert Organization.create!(name: "No Domain B").persisted?
  end

  test "database enforces unique domain" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      Organization.insert!({ name: "Dup", slug: "dup", domain: "terrapower.com" })
    end
  end

  test "status must be a known value" do
    org = Organization.new(name: "Mystery", status: "bankrupt")
    assert_not org.valid?
    assert_includes org.errors[:status], "is not included in the list"
  end

  test "starts pending and can be verified" do
    org = organizations(:terrapower)
    assert org.pending?
    assert_not_includes Organization.verified, org

    org.verify!(by: "human:tosin")
    assert org.verified?
    assert_equal "human:tosin", org.verified_by
    assert_includes Organization.verified, org
  end

  test "confidence must be between 0 and 1" do
    org = organizations(:terrapower)
    org.confidence = 1.5
    assert_not org.valid?
  end

  test "an organization can hold a role only once" do
    role = Role.create!(key: "reactor_vendor", name: "Reactor vendor")
    org = organizations(:westinghouse)
    org.organization_roles.create!(role: role)

    duplicate = org.organization_roles.build(role: role)
    assert_not duplicate.valid?
  end
end
