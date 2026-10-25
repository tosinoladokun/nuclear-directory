require "test_helper"

# A company's country only when a source states it (Data Quality, 24 Oct).
class OrganizationCountryTest < ActiveSupport::TestCase
  test "a company a crawler creates has no country until a source states one" do
    result = Directory::FactWriter.write(:organization, { name: "Countryless Fission" })
    assert result.ok?
    assert_nil Organization.find(result.id).country_code
    assert_nil Organization.create!(name: "Also Countryless").country_code

    Directory::FactWriter.write(:organization, { id: result.id, country_code: "ca" })
    assert_equal "CA", Organization.find(result.id).country_code
  end
end
