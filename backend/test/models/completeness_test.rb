require "test_helper"

# The outcome's completeness count (PM, 29 Oct): published companies with a
# category, a website, a description and an HQ state.
class CompletenessTest < ActiveSupport::TestCase
  BY = "human:tosin"

  def company(name, **attributes)
    Organization.create!(name:, verification_status: "verified", verified_by: BY, **attributes).tap do |org|
      org.evidence.create!(source: sources(:press_release), quote: "#{name}.", found_by: "human", confidence: 1)
    end
  end

  def in_fuel(org)
    role = Role.find_or_create_by!(key: "fuel") { |r| r.name = "Fuel" }
    org.organization_roles.create!(role:, verification_status: "verified", verified_by: BY)
      .evidence.create!(source: sources(:press_release), quote: "#{org.name} makes fuel.", found_by: "human", confidence: 1)
  end

  test "counts published companies with all four parts, and lists what each other one lacks" do
    whole = company("Whole Fuel Co", website: "https://whole.example.com", description: "Makes fuel.", hq_city: "Oak Ridge", hq_state: "TN").tap { |org| in_fuel(org) }
    company("Bare Co")
    no_hq = company("No HQ Co", website: "https://nohq.example.com", description: "Makes fuel.").tap { |org| in_fuel(org) }
    company("Abroad Co", website: "https://ab.example.com", description: "Makes fuel.", hq_city: "Toronto", country_code: "CA").tap { |org| in_fuel(org) }
    company("No City Co", website: "https://nc.example.com", description: "Makes fuel.", hq_state: "TX").tap { |org| in_fuel(org) }
    Organization.create!(name: "Pending Co", website: "https://p.example.com", description: "x", hq_state: "TX") # not published

    report = Completeness.new

    assert_includes Category.buckets.flat_map { |c| Organization.where(id: Bucket.organization_ids(c)).pluck(:id) }, whole.id
    assert_equal [ 2, 5 ], [ report.complete_count, report.total ]
    assert_equal({ "category" => 1, "website" => 1, "description" => 1, "hq" => 3 }, report.missing_counts)
    rows = CSV.parse(report.to_csv, headers: true)
    assert_equal [ "Bare Co", "No City Co", "No HQ Co" ], rows.map { |row| row["name"] }, "least complete first; the complete one isn't listed"
    assert_equal [ "", "", "", "yes" ], rows.find { |row| row["slug"] == no_hq.slug }.fields("missing_category", "missing_website",
      "missing_description", "missing_hq")
  end
end
