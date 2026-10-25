require "test_helper"

# #559: a company row's middle column, 40 characters at most; until it's
# written, role · specialty from what's published, for a whole list at once.
class ShortDescriptionTest < ActiveSupport::TestCase
  setup do
    @company = Organization.create!(name: "Short Fission Co", verification_status: "verified", verified_by: "human:tosin")
  end

  def role(key, name, parent: nil) = Role.find_by(key:) || Role.create!(key:, name:, parent:)
  def give_role(company, role) = OrganizationRole.create!(organization: company, role:, verification_status: "verified", verified_by: "human:tosin")
  def give_technology(company, key, name, parent: nil)
    technology = Technology.find_by(key:) || Technology.create!(key:, name:, parent:)
    OrganizationTechnology.create!(organization: company, technology:, verification_status: "verified", verified_by: "human:tosin")
  end

  test "40 characters at most, squished; empty is none" do
    @company.update!(short_description: "  Uranium enrichment,   including HALEU ")
    assert_equal "Uranium enrichment, including HALEU", @company.short_description
    assert_not @company.update(short_description: "x" * 41)
    assert @company.update(short_description: "x" * 40)
    @company.update!(short_description: "   ")
    assert_nil @company.reload.short_description
  end

  test "a written description wins; else the category's role, then a technology (SMR, never Fission alone)" do
    fission = Technology.find_by(key: "fission") || Technology.create!(key: "fission", name: "Fission")
    give_role(@company, role("reactor_vendor", "Reactor vendor"))
    give_technology(@company, "fission", "Fission")
    give_technology(@company, "smr", "Small modular reactor", parent: fission)
    developers = Category.find("reactor-developers")
    assert_equal "Reactor designer · SMR", ShortDescription.for([ @company ], category: developers)[@company.id]

    @company.update!(short_description: "Molten salt–cooled reactor design")
    assert_equal "Molten salt–cooled reactor design", ShortDescription.for([ @company ], category: developers)[@company.id]
  end

  test "with no technology, the next role; the category's role comes first" do
    give_role(@company, role("isotopes", "Isotopes"))
    give_role(@company, role("enrichment", "Enrichment"))
    assert_equal "Isotope producer · Enrichment", ShortDescription.for([ @company ], category: Category.find("fuel"))[@company.id]
    assert_nil ShortDescription.for([ Organization.create!(name: "Bare Co", verification_status: "verified", verified_by: "human:tosin") ])
      .values.first, "nothing published: nothing shown"
  end

  test "a whole list in a fixed number of queries, never one per row" do
    companies = 3.times.map { |i| Organization.create!(name: "List Co #{i}", verification_status: "verified", verified_by: "human:tosin") }
    companies.each { |company| give_role(company, role("enrichment", "Enrichment")) }
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ShortDescription.for(companies) }
    few = queries
    companies += 5.times.map { |i| Organization.create!(name: "More Co #{i}", verification_status: "verified", verified_by: "human:tosin") }
    queries = 0
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { ShortDescription.for(companies) }
    assert_equal few, queries
  end

  test "no full stop; the database refuses over 40 too; a link's short phrase has the same limit" do
    assert_not @company.update(short_description: "Uranium enrichment.")
    assert_raises(ActiveRecord::StatementInvalid) { Organization.transaction(requires_new: true) { @company.update_columns(short_description: "x" * 41) } }
    other = Organization.create!(name: "Phrase Partner Co", verification_status: "verified", verified_by: "human:tosin")
    link = Relationship.create!(from_organization: @company, to_organization: other, relationship_type: "supplies", verification_status: "pending")
    assert link.update(short_phrase: " LEU and   HALEU enrichment ")
    assert_equal "LEU and HALEU enrichment", link.short_phrase
    assert_not link.update(short_phrase: "x" * 41)
    assert_raises(ActiveRecord::StatementInvalid) { Relationship.transaction(requires_new: true) { link.update_columns(short_phrase: "x" * 41) } }
  end
end
