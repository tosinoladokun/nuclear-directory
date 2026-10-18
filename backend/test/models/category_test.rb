require "test_helper"

class CategoryTest < ActiveSupport::TestCase
  test "nine buckets and Plants and sites, in display order" do
    assert_equal [ "Developers", "Fuel and materials", "Components and manufacturing", "Waste and decommissioning",
      "Utilities and operators", "Plants and sites", "Power buyers", "Services and engineering", "Investors",
      "Government and research" ], Category.all.map(&:name)
    assert_equal 9, Category.buckets.size
    assert_not_includes Category.buckets.map(&:key), "plants"
  end

  # Slugs never change once launched (#281): a bucket that took over a
  # category keeps its address.
  test "slugs stay as launched" do
    assert_equal %w[reactor-developers fuel components waste-decommissioning utilities plants power-buyers services investors
      government-research], Category.all.map(&:key)
  end

  test "short labels where only a short one fits, approved by Tosin; others keep their name" do
    assert_equal({ "components" => "Components", "waste-decommissioning" => "Waste", "services" => "Services",
      "government-research" => "Government", "utilities" => "Plant operators" }, Category.all.select(&:short).to_h { |c| [ c.key, c.short_name ] })
    assert_equal "Developers", Category.find("reactor-developers").short_name
  end

  test "find by key" do
    assert_equal "Fuel and materials", Category.find("fuel").name
    assert_equal "fuel", Category.find("fuel").to_param
    assert_nil Category.find("nope")
    assert_nil Category.find("fusion"), "fusion is a tag now"
  end

  # Keys docs/DATA.md decided that arrive with their first sourced company.
  DECIDED_KEYS = %w[components waste_decommissioning isotopes university project_developer research_organization].freeze

  test "every role key a bucket uses is a seeded role, or one DATA.md decided" do
    roles_block = File.read(Rails.root.join("db/seeds.rb"))[/^ROLES = \[(.*?)^\]\.freeze/m, 1]
    seeded_roles = roles_block.scan(/\[ "([a-z_]+)", /).flatten

    assert_includes seeded_roles, "reactor_vendor"
    assert_not_includes seeded_roles, "fusion"
    Category.all.flat_map(&:role_keys).each { |key| assert_includes seeded_roles + DECIDED_KEYS, key }
  end
end
