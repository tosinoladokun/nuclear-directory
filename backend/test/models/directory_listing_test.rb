require "test_helper"
require_relative "../support/directory_builders"

class DirectoryListingTest < ActiveSupport::TestCase
  include DirectoryBuilders

  setup do
    fuel = role("fuel")
    enrichment = role("enrichment", parent: fuel)
    vendor = role("reactor_vendor")
    salt = role("molten_salt", parent: role("coolant"))
    smr = technology("smr", "Small modular reactor", parent: technology("fission"))

    @centrus = company("Centrus Energy", state: "MD", roles: [ enrichment ])
    @kairos = company("Kairos Power", state: "CA", roles: [ vendor, salt ], techs: [ smr ], aliases: [ "Kairos Power, LLC" ])
    @cfs = company("Commonwealth Fusion Systems", techs: [ technology("fusion") ])
    @khosla = company("Khosla Ventures", roles: [ role("venture_capital") ])
    @amazon = company("Amazon")
    @pending = company("Pending Reactors", roles: [ vendor ], verified: false)

    @vogtle = plant("Plant Vogtle", state: "GA", facility_type: "power_reactor")
    @unit = plant("Vogtle Unit 3", parent: @vogtle)

    cite!(link(@amazon, "invests_in", @kairos))
    link(@kairos, "owns", @unit)
    link(@centrus, "supplies", @kairos, verified: false)
    # Buckets and tags count sourced facts only (#281).
    cite!(@centrus, @kairos, @cfs, @khosla, @amazon, @pending)
  end

  def names(listing) = listing.companies.map(&:name)

  test "a bucket includes child roles and only verified companies" do
    # Centrus through enrichment (under fuel); Kairos through its molten salt coolant (under coolant).
    assert_equal [ "Centrus Energy", "Kairos Power" ], names(DirectoryListing.new(category: "fuel"))
    assert_equal [ "Kairos Power" ], names(DirectoryListing.new(category: "reactor-developers"))
  end

  test "investors include companies with a verified invests_in link" do
    assert_equal [ "Amazon", "Khosla Ventures" ], names(DirectoryListing.new(category: "investors"))
  end

  test "fusion is a tag with its own list, of companies only" do
    listing = DirectoryListing.new(tag: "fusion")

    assert_equal [ "Commonwealth Fusion Systems" ], names(listing)
    assert_empty listing.plants
    assert_equal [ "Commonwealth Fusion Systems" ], names(DirectoryListing.new(tag: "fusion", q: "fusion")), "search within a tag"
    assert_nil DirectoryListing.new(category: "fusion").category, "no longer a category"
  end

  test "power plants lists sites, not units, and no companies" do
    listing = DirectoryListing.new(category: "plants")

    assert_equal [ "Plant Vogtle" ], listing.plants.map(&:name)
    assert_empty listing.companies
  end

  test "browsing with no category lists every verified company and no plants" do
    listing = DirectoryListing.new

    assert_equal [ "Amazon", "Centrus Energy", "Commonwealth Fusion Systems", "Kairos Power", "Khosla Ventures" ], names(listing)
    assert_empty listing.plants
  end

  test "search matches names, aliases, roles and technologies, and includes plants" do
    assert_equal [ "Kairos Power" ], names(DirectoryListing.new(q: "Kairos Power, LLC"))
    assert_equal [ "Kairos Power" ], names(DirectoryListing.new(q: "smr"))
    assert_equal [ "Centrus Energy" ], names(DirectoryListing.new(q: "enrichment"))
    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(q: "vogtle").plants.map(&:name)
    assert_empty names(DirectoryListing.new(q: "pending"))
  end

  test "searching a plant's other name finds it, through the site or a unit" do
    @vogtle.aliases.create!(alias: "Alvin W. Vogtle Electric Generating Plant")
    @unit.aliases.create!(alias: "VEGP-3")

    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(q: "alvin w vogtle").plants.map(&:name)
    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(q: "VEGP 3").plants.map(&:name)
    assert_empty DirectoryListing.new(q: "!!").plants

    plant("Vogtle Unit 5", parent: @vogtle, verified: false).aliases.create!(alias: "VEGP-5")
    assert_empty DirectoryListing.new(q: "VEGP 5").plants, "a pending unit's alias doesn't count"
  end

  test "search matches deal descriptions, so topics like HALEU find the companies involved" do
    Role.find_by!(key: "fuel").update!(description: "Mines, converts or enriches fuel (uranium, HALEU).")
    Relationship.find_by!(from_organization: @amazon).update!(description: "Funds a HALEU fuel line.")

    assert_equal [ "Amazon", "Kairos Power" ], names(DirectoryListing.new(q: "haleu"))
  end

  test "a pending site appears once one of its units is verified" do
    pending_site = plant("Salem Nuclear Generating Station", verified: false)
    plant("Hope Creek", verified: false)
    plant("Salem Unit 1", parent: pending_site)

    assert_equal [ "Plant Vogtle", "Salem Nuclear Generating Station" ], DirectoryListing.new(category: "plants").plants.map(&:name)
    assert_equal 2, DirectoryListing.category_counts["plants"]
  end

  test "a technology filter narrows plants too, by the site's or a unit's technology" do
    fusion_site = plant("Orion", technology: Technology.find_by!(key: "fusion"))
    @unit.update!(technology: Technology.find_by!(key: "smr"))

    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(category: "plants", technology: "fission").plants.map(&:name)
    assert_equal [ fusion_site.name ], DirectoryListing.new(category: "plants", technology: "fusion").plants.map(&:name)
    # Coolant is a company role: it hides plants in search results, and isn't an option on the plants list.
    assert_empty DirectoryListing.new(q: "orion", technology: "molten_salt").plants
    assert_nil DirectoryListing.new(category: "plants", technology: "molten_salt").technology
  end

  test "state options come from companies and verified sites, not units or a pending site's own place" do
    plant("Unit In Nevada", parent: @vogtle, state: "NV")
    pending_site = plant("Pending Station", verified: false, state: "OR")
    plant("Pending Unit 1", parent: pending_site)

    options = DirectoryListing.new(category: "plants").state_options
    assert_not_includes options, "NV"
    assert_not_includes options, "OR"
    assert_includes options, "GA"
    assert_nil DirectoryListing.new(category: "plants", state: "OR").state
  end

  test "a pending site's own technology doesn't match; its verified unit's does" do
    fusion = technology("fusion_magnetic", "Magnetic confinement")
    plant("Pending Fusion", verified: false, technology: fusion).tap { |site| plant("Pending Fusion Unit", parent: site) }
    shown = plant("Shown Site", verified: false).tap { |site| plant("Shown Unit", parent: site, technology: fusion) }

    assert_equal [ shown.name ], DirectoryListing.new(category: "plants", technology: "fusion_magnetic").plants.map(&:name)
    assert_equal [ shown.name ], DirectoryListing.new(q: "magnetic").plants.map(&:name)

    own_only = technology("pebble_bed", "Pebble bed")
    plant("Pebble Site", verified: false, technology: own_only).tap { |site| plant("Pebble Unit", parent: site) }
    assert_not_includes DirectoryListing.new(category: "plants").technology_options.map(&:last), "pebble_bed"
  end

  test "a rejected site never appears, even with a verified unit" do
    rejected = Facility.create!(name: "Rejected Station", verification_status: "rejected", verified_by: "human:test")
    plant("Rejected Unit 1", parent: rejected)

    assert_not_includes DirectoryListing.new(category: "plants").plants.map(&:name), "Rejected Station"
  end

  test "technologies used only by plants are filter options, and coolants aren't offered for plants" do
    plant("Orion", technology: technology("fusion_magnetic", "Magnetic confinement"))

    assert_includes DirectoryListing.new(category: "plants").technology_options.map(&:last), "fusion_magnetic"
    assert_equal "fusion_magnetic", DirectoryListing.new(category: "plants", technology: "fusion_magnetic").technology
    assert_not_includes DirectoryListing.new(category: "plants").technology_options.map(&:last), "molten_salt"
  end

  test "filter options come only from companies and plants the public can see" do
    hidden_tech = technology("pebble_bed", "Pebble bed")
    company("Pending Pebbles", techs: [ hidden_tech ], verified: false)
    rejected = Facility.create!(name: "Rejected Site", verification_status: "rejected", verified_by: "human:test")
    plant("Rejected Unit", parent: rejected, technology: technology("sfr", "Sodium fast reactor"))
    OrganizationRole.create!(organization: @pending, role: role("lead_coolant", parent: Role.find_by!(key: "coolant")), **verification(true))

    options = DirectoryListing.new.technology_options.map(&:last)
    assert_not_includes options, "pebble_bed"
    assert_not_includes options, "sfr"
    assert_not_includes options, "lead_coolant"
    assert_includes options, "molten_salt"
  end

  test "searching a technology finds plants of that technology, through the site or a unit" do
    site = plant("Fermi America", technology: Technology.find_by!(key: "smr"))
    plant("Clinch River", verified: false).tap do |river|
      plant("Clinch River Unit 1", parent: river, technology: Technology.find_by!(key: "smr"))
    end

    assert_equal [ "Clinch River", site.name ], DirectoryListing.new(q: "SMR").plants.map(&:name).sort
  end

  test "filter options come only from the kinds of record the listing shows" do
    plant("Orion", state: "NM", technology: technology("fusion_magnetic", "Magnetic confinement"))

    companies_page = DirectoryListing.new
    assert_not_includes companies_page.technology_options.map(&:last), "fusion_magnetic"
    assert_not_includes companies_page.state_options, "NM"

    plants_page = DirectoryListing.new(category: "plants")
    assert_includes plants_page.technology_options.map(&:last), "fusion_magnetic"
    assert_not_includes plants_page.technology_options.map(&:last), "smr"
    assert_not_includes plants_page.state_options, "CA"

    search = DirectoryListing.new(q: "o")
    assert_includes search.technology_options.map(&:last), "fusion_magnetic"
    assert_includes search.state_options, "CA"
  end

  test "a link on a pending site itself doesn't make the site searchable" do
    site = plant("Quiet Site", verified: false).tap { |s| plant("Quiet Unit", parent: s) }
    FacilityRelationship.create!(organization: @kairos, facility: site, relationship_type: "owns", verification_status: "verified", verified_by: "human:test", description: "Zebra deal.")

    assert_empty DirectoryListing.new(q: "zebra").plants
  end

  test "search ignores unsourced and ended links, which plant pages hide" do
    unsourced = FacilityRelationship.find_by!(facility: @unit)
    unsourced.update!(description: "Yak deal.")
    assert_empty DirectoryListing.new(q: "yak").plants

    unsourced.evidence.create!(source: default_source, found_by: "human", confidence: 1)
    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(q: "yak").plants.map(&:name)

    unsourced.update!(ended_on: Date.new(2020, 1, 1))
    assert_empty DirectoryListing.new(q: "yak").plants
  end

  test "a parent technology filter includes its sub-technologies" do
    assert_equal [ "Kairos Power" ], names(DirectoryListing.new(technology: "fission"))
  end

  test "a unit's name finds its site" do
    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(q: "Unit 3").plants.map(&:name)
  end

  test "search matches plant link descriptions, finding the company and the site" do
    cite!(FacilityRelationship.find_by!(facility: @unit)).update!(description: "Co-owned with MEAG Power.")
    listing = DirectoryListing.new(q: "meag")

    assert_equal [ "Kairos Power" ], names(listing)
    assert_equal [ "Plant Vogtle" ], listing.plants.map(&:name)
  end

  test "a query of only punctuation doesn't match every company" do
    assert_empty names(DirectoryListing.new(q: "..."))
  end

  test "sites carry their verified units' count and capacity" do
    @unit.update!(capacity_mw: 1117, status: "operating")
    plant("Vogtle Unit 4", parent: @vogtle, capacity_mw: 1117, status: "operating")
    plant("Vogtle Unit 5", parent: @vogtle, capacity_mw: 500, status: "operating", verified: false)
    plant("Vogtle Unit 1", parent: @vogtle, capacity_mw: 400, status: "shut_down")
    site = DirectoryListing.new(category: "plants").plants.first

    assert_equal %w[operating operating shut_down], site.units_statuses.sort
    assert_equal 2234, site.units_capacity_mw
  end

  test "search puts name matches before matches through roles or deals" do
    Relationship.find_by!(from_organization: @amazon).update!(description: "Backs Kairos with equity.")
    company("Akairos Labs")

    assert_equal [ "Kairos Power", "Akairos Labs", "Amazon" ], names(DirectoryListing.new(q: "kairos"))
  end

  test "an alias that starts with the query ranks with name matches" do
    Relationship.find_by!(from_organization: @amazon).update!(description: "Backs Kairos with equity.")
    company("Akairos Labs")
    company("Zephyr Energy", aliases: [ "Kairos Fuel Co" ])

    assert_equal [ "Kairos Power", "Zephyr Energy", "Akairos Labs", "Amazon" ], names(DirectoryListing.new(q: "kairos"))
  end

  test "search within a category" do
    assert_empty names(DirectoryListing.new(category: "reactor-developers", q: "centrus"))
  end

  test "technology filter takes a technology or a coolant" do
    assert_equal [ "Kairos Power" ], names(DirectoryListing.new(technology: "smr"))
    assert_equal [ "Kairos Power" ], names(DirectoryListing.new(technology: "molten_salt"))
    assert_equal 5, names(DirectoryListing.new(technology: "unknown")).size
  end

  test "state filter applies to companies and plants" do
    assert_equal [ "Centrus Energy" ], names(DirectoryListing.new(state: "md"))
    assert_equal [ "Plant Vogtle" ], DirectoryListing.new(category: "plants", state: "GA").plants.map(&:name)
  end

  test "connections count only verified links, and a site counts its units' links" do
    counts = DirectoryListing.new.companies.to_h { |c| [ c.name, c.connections_count ] }
    assert_equal 2, counts["Kairos Power"]
    assert_equal 0, counts["Centrus Energy"]

    assert_equal 1, DirectoryListing.new(category: "plants").plants.first.connections_count
  end

  test "sort by most connected" do
    assert_equal "Kairos Power", DirectoryListing.new(sort: "connections").companies.first.name
  end

  test "unknown values from the URL are ignored" do
    listing = DirectoryListing.new(category: "nope", sort: "nope", q: "  ", technology: "nope", state: "ZZ")

    assert_nil listing.category
    assert_equal "name", listing.sort
    assert_not listing.searching?
    assert_nil listing.technology
    assert_nil listing.state
    assert_not listing.filtered?
  end

  test "category counts for the pills" do
    counts = DirectoryListing.category_counts

    assert_equal 2, counts["fuel"]
    assert_equal 2, counts["investors"]
    assert_equal 1, counts["plants"]
    assert_equal 0, counts["power-buyers"]
  end

  test "filter options come from verified data" do
    listing = DirectoryListing.new

    assert_equal [ [ "Small modular reactor", "smr" ], [ "Molten salt coolant", "molten_salt" ] ],
      listing.technology_options.select { |_, key| %w[smr molten_salt].include?(key) }
    assert_equal %w[CA MD], listing.state_options
  end

  # Unpublishing (#87, #98): what hangs on an unpublished company or plant
  # stops counting anywhere public, and comes back when it's republished.
  test "an unpublished company disappears, and so do its links, from other companies' results and counts" do
    @kairos.unpublish!(by: "human:test")

    assert_not_includes names(DirectoryListing.new), "Kairos Power"
    assert_equal 0, DirectoryListing.new.companies.find { |c| c.name == "Amazon" }.connections_count,
      "Amazon's investment in Kairos no longer counts"
    assert_includes names(DirectoryListing.new(category: "investors")), "Khosla Ventures", "its own role still counts"
    assert_not_includes names(DirectoryListing.new(category: "investors")), "Amazon", "its only investment is hidden"
    assert_not_includes DirectoryListing.new.technology_options.map(&:last), "molten_salt"
    assert_equal 0, DirectoryListing.new(category: "plants").plants.first.connections_count, "Kairos's plant link is hidden"
    assert_not_includes DirectoryListing.new.state_options, "CA"

    @kairos.verify!(by: "human:test")
    assert_includes names(DirectoryListing.new), "Kairos Power"
  end

  test "an unpublished site disappears with its units and their links" do
    kairos_connections = -> { DirectoryListing.new.companies.find { |c| c.name == "Kairos Power" }.connections_count }
    assert_equal 2, kairos_connections.call, "Amazon's investment and the Vogtle unit"
    @vogtle.unpublish!(by: "human:test")

    assert_empty DirectoryListing.new(category: "plants").plants
    assert_empty DirectoryListing.new(q: "Vogtle Unit 3").plants
    assert_equal 1, kairos_connections.call, "the link to the hidden unit no longer counts"
    assert_not_includes DirectoryListing.new.state_options, "GA"
  end

  test "an unpublished unit no longer counts toward its site" do
    second = plant("Vogtle Unit 4", parent: @vogtle, capacity_mw: 1100)
    second.unpublish!(by: "human:test")

    site = DirectoryListing.new(category: "plants").plants.first
    assert_equal 1, site.units_statuses.size
  end

  test "Developers narrows to reactor designers or project developers; a company with both is in each" do
    builder = company("Blue Builders", roles: [ role("project_developer") ])
    both = company("Both Ways Nuclear", roles: [ Role.find_by!(key: "reactor_vendor"), Role.find_by!(key: "project_developer") ])
    cite!(builder, both)

    assert_equal [ "Blue Builders", "Both Ways Nuclear", "Kairos Power" ], names(DirectoryListing.new(category: "reactor-developers"))
    assert_equal [ "Both Ways Nuclear", "Kairos Power" ], names(DirectoryListing.new(category: "reactor-developers", role: "reactor_vendor"))
    assert_equal [ "Blue Builders", "Both Ways Nuclear" ], names(DirectoryListing.new(category: "reactor-developers", role: "project_developer"))
    assert DirectoryListing.new(category: "reactor-developers", role: "project_developer").filtered?
  end

  test "a role that isn't one of the bucket's, or on a one-role bucket, is dropped" do
    assert_nil DirectoryListing.new(category: "reactor-developers", role: "fuel").role
    assert_nil DirectoryListing.new(category: "components", role: "components").role
    assert_nil DirectoryListing.new(role: "reactor_vendor").role
  end

  test "search ignores spacing and punctuation, and finds every word of a name in any form (#431)" do
    nextera = company("NextEra Energy")
    browns = plant("Browns Ferry Nuclear Plant", state: "AL", facility_type: "power_reactor")
    cite!(nextera)

    assert_includes names(DirectoryListing.new(q: "next era")), "NextEra Energy"
    assert_includes names(DirectoryListing.new(q: "Next-Era")), "NextEra Energy"
    assert_includes DirectoryListing.new(q: "brown ferry").plants.map(&:name), browns.name
    assert_empty names(DirectoryListing.new(q: "next banana")), "every word must be in the name"
  end
end
