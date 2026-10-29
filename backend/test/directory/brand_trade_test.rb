require "test_helper"

# DQ, 29 Oct: "Standard Nuclear, Inc." (a fuel maker) was matched to Standard
# Power (a data center developer) as a legal-entity variant.
class Directory::BrandTradeTest < ActiveSupport::TestCase
  def company(name) = Organization.create!(name:, verification_status: "verified", verified_by: "human:tosin").tap { |o| o.aliases.create!(alias: name) }

  test "names that say different trades aren't one brand; the same or no trade still is" do
    company("Standard Power")
    assert_empty Directory::Lookup.same_brand_organizations("Standard Nuclear, Inc.")
    duke = company("Duke Energy")
    assert_equal [ duke.id ], Directory::Lookup.same_brand_organizations("Duke Energy Carolinas, LLC").map(&:id)
    dominion = company("Dominion Energy")
    assert_equal [ dominion.id ], Directory::Lookup.same_brand_organizations("Dominion Generation").map(&:id), "energy and generation are one trade"
    acme = company("Acme Fission")
    assert_equal [ acme.id ], Directory::Lookup.same_brand_organizations("Acme Fission Nuclear, LLC").map(&:id), "one side names no trade"
  end
end
