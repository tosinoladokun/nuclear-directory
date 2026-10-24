require "test_helper"

class SeedsTest < ActiveSupport::TestCase
  COUNTED = %w[Organization OrganizationAlias OrganizationRole OrganizationTechnology Facility Relationship
    FacilityRelationship Source Evidence Role Technology].map { |model| "#{model}.count" }

  def load_seeds
    silence_warnings { load Rails.root.join("db/seeds.rb") }
  end

  # Production was first seeded from these files (main at #100, 2026-10-09);
  # every later seed must load on top of them, as a re-seed does.
  test "the current seed loads on top of the seed production started with" do
    load_seeds
    Organization.destroy_all
    Facility.destroy_all
    Seed::OrganizationLoader.new(file_fixture("seed_at_launch/organizations").to_s, facilities: nil).load!
    assert Organization.exists?(slug: "urenco-usa"), "the old seed had Urenco USA as its own company"

    assert_empty Seed::OrganizationLoader.new(Rails.root.join("db/seeds/organizations")).collisions
    load_seeds

    urenco = Organization.find_by!(slug: "urenco")
    assert Organization.find_by!(slug: "urenco-usa").unpublished?, "merged into Urenco"
    assert_equal urenco.id, Directory::Lookup.organization(name: "Urenco USA").id
    # The legal name stays as an alias once a quote names it (Oklo's 10-Q).
    assert_equal [ "Meta", "Meta Platforms, Inc." ], Organization.find_by!(slug: "meta-platforms").aliases.pluck(:alias).sort
  end

  test "every suggestion in the home page's pool finds 3 or more results in the seed" do
    load_seeds
    counts = HomeSuggestions::POOL.to_h do |suggestion|
      listing = DirectoryListing.new(q: suggestion.query)
      [ suggestion.label, listing.companies.size + listing.plants.size ]
    end

    assert counts.values.all? { |count| count >= 3 }, "a suggestion with fewer than 3 results: #{counts.inspect}"
  end

  test "seeds roles and technologies" do
    load_seeds

    assert Role.find_by!(key: "reactor_vendor").description.present?
    assert_equal Role.find_by!(key: "coolant"), Role.find_by!(key: "molten_salt").parent
    assert_equal Role.find_by!(key: "fuel"), Role.find_by!(key: "enrichment").parent
    assert_equal Technology.find_by!(key: "fission"), Technology.find_by!(key: "smr").parent
    assert_nil Technology.find_by!(key: "fusion").parent
  end

  test "loads the hand-checked organizations as verified facts with evidence" do
    load_seeds

    assert_equal 122, Organization.verified.count
    assert_equal 137, OrganizationRole.verified.count
    assert_equal 59, OrganizationTechnology.verified.count
    # Each operator company the NRC list row named carries that row as its own evidence.
    %w[ameren-ue arizona-public-service-co dte-electric-company duke-energy-florida duke-energy energy-harbor-nuclear-corp firstenergy-nuclear-operating-co indiana-michigan-power-co nebraska-public-power-district northern-states-power-company-minnesota pacific-gas-electric-co pseg-nuclear-llc south-carolina-electric-gas-co southern-nuclear-operating-co stp-nuclear-operating-co susquehanna-nuclear-llc wolf-creek-nuclear-operating-corp].each do |slug|
      assert Organization.find_by!(slug:).evidence.any?, "#{slug} has no quoted evidence"
    end
    # A company the NRC decommissioning crawl found carries its NRC identity quote on its own record.
    %w[adp-cr3 kewaunee-solutions-inc northstar-vallecitos-llc-nsv tmi-2-solutions].each do |slug|
      assert Organization.find_by!(slug:).evidence.any?, "#{slug} has no quoted evidence"
    end
    assert_equal 79, Relationship.verified.count
    assert_equal 53, Facility.verified.count
    # 4 plant links wait for a direct quote (owns/operates not stated by the source).
    assert_equal [ 76, 6 ], [ FacilityRelationship.verified.count, FacilityRelationship.pending.count ]
    assert_equal 28, FacilityAlias.count
    assert_equal "Kemmerer Unit 1", Directory::Lookup.facility(name: "Kemmerer Unit 1 (Natrium)")&.name, "found by its other name"
    assert_equal [ "human:tosin" ], Relationship.distinct.pluck(:verified_by)
    assert_equal [ 1 ], OrganizationRole.distinct.pluck(:confidence)

    georgia_power = Directory::Lookup.organization(name: "Georgia Power Company")
    southern = Directory::Lookup.organization(name: "Southern Company")
    link = Relationship.find_by!(from_organization_id: georgia_power.id, to_organization_id: southern.id)
    assert link.subsidiary_of?
    assert_equal "human", link.evidence.sole.found_by
    assert_match "Georgia Power", link.evidence.sole.quote
  end

  test "loads the fuel chain from the gap research" do
    load_seeds

    mill = Facility.find_by!(name: "White Mesa Mill")
    assert mill.mill?
    assert mill.operating?, "a later mention without status doesn't blank it"
    assert_equal "UT", mill.state

    converdyn = Directory::Lookup.organization(name: "ConverDyn")
    solstice = Directory::Lookup.organization(name: "Solstice Advanced Materials")
    assert Relationship.exists?(from_organization_id: converdyn.id, to_organization_id: solstice.id,
      relationship_type: "subsidiary_of")
    assert_includes Organization.find(converdyn.id).roles.pluck(:key), "conversion"
  end

  test "Urenco USA is part of Urenco (one company per brand)" do
    load_seeds

    urenco = Directory::Lookup.organization(name: "Urenco USA")
    assert_equal "Urenco", urenco.name
    eunice = Facility.find_by!(name: "Urenco USA enrichment facility")
    assert_equal [ "Urenco" ], eunice.organizations.pluck(:name)
    assert_not Relationship.subsidiary_of.exists?(from_organization_id: urenco.id)
  end

  test "Plant Vogtle is one site-level record covering every unit" do
    load_seeds

    vogtle = Facility.find_by!(name: "Plant Vogtle")
    assert_nil Facility.find_by(name: "Plant Vogtle Units 3 & 4")
    links = vogtle.facility_relationships.includes(:organization).to_h { |link| [ link.organization.slug, link ] }
    assert links["georgia-power"].owns?
    assert links["westinghouse-electric-company"].vendor_for?
    assert_match "Units 3 and 4", links["westinghouse-electric-company"].description
  end

  test "companies are named by brand, with the legal name kept" do
    load_seeds

    westinghouse = Organization.find_by!(slug: "westinghouse-electric-company")
    assert_equal [ "Westinghouse", "Westinghouse Electric Company LLC" ], [ westinghouse.name, westinghouse.legal_name ]
    assert_equal westinghouse.id, Directory::Lookup.organization(name: "Westinghouse Electric Company LLC").id
    assert_equal "X-energy", Directory::Lookup.organization(name: "X-Energy, Inc.").name
  end

  test "plant details carry their own sources, and co-owners their stakes" do
    load_seeds

    hermes = Facility.find_by!(name: "Hermes 2")
    assert_equal [ "power_reactor", "under_construction", "Oak Ridge", "TN" ],
      hermes.slice(:facility_type, :status, :city, :state).values
    assert hermes.evidence.count >= 4, "one evidence row per sourced field"

    # A city only where a source says the site is in it (#225); "near" a town isn't a city.
    assert_equal [ "Palo", "IA" ], Facility.find_by!(name: "Duane Arnold Energy Center").slice(:city, :state).values
    assert_nil Facility.find_by!(name: "White Mesa Mill").city, "its source says only near Blanding"

    vogtle = Facility.find_by!(name: "Plant Vogtle")
    shares = vogtle.facility_relationships.owns.includes(:organization).to_h { |l| [ l.organization.name, l.ownership_pct.to_f ] }
    assert_equal({ "Georgia Power" => 45.7, "Oglethorpe Power" => 30.0, "MEAG Power" => 22.7, "Dalton Utilities" => 1.6 }, shares)
    assert_match "Units 3 and 4", vogtle.facility_relationships.owns.first.description

    doe = Organization.find_by!(slug: "us-department-of-energy")
    assert_equal [ "Advanced Test Reactor", "American Centrifuge Plant", "High Flux Isotope Reactor" ],
      doe.facility_relationships.owns.joins(:facility).pluck("facilities.name").sort
    # Tosin, 2026-10-10: links whose quote doesn't state ownership wait in review.
    assert_equal [ "American Centrifuge Plant" ], doe.facility_relationships.owns.verified.joins(:facility).pluck("facilities.name")
    assert_equal [ "Advanced Test Reactor", "High Flux Isotope Reactor" ],
      doe.facility_relationships.owns.pending.joins(:facility).pluck("facilities.name").sort
    # Long Mott Energy's unsupported owns link was dropped (#322); it's a project developer instead.
    long_mott = Organization.find_by!(slug: "long-mott-energy")
    assert_empty long_mott.facility_relationships
    assert_equal [ "project_developer" ], long_mott.roles.pluck(:key)
  end

  test "DOE-funded companies carry sourced categories; new category keys exist (#322)" do
    load_seeds

    assert_equal %w[components fuel], Organization.find_by!(name: "BWXT").roles.pluck(:key).sort
    assert_equal [ "waste_decommissioning" ], Organization.find_by!(name: "NAC International").roles.pluck(:key)
    nfs = Organization.find_by!(name: "Nuclear Fuel Services")
    assert_equal "BWXT", Relationship.find_by!(from_organization: nfs, relationship_type: "subsidiary_of").to_organization.name
    alabama = Organization.find_by!(name: "Alabama Power")
    assert_equal [ "Joseph M Farley" ], alabama.facility_relationships.owns.joins(:facility).pluck("facilities.name")
    assert_equal alabama.id, Directory::Lookup.organization(name: "Alabama Power Co").id, "EIA's spelling still finds it"
    assert_equal [ "utility" ], alabama.roles.pluck(:key)
    assert_equal %w[components isotopes research_organization university waste_decommissioning], Role.where(key: %w[components isotopes waste_decommissioning university research_organization]).pluck(:key).sort
  end

  test "the approved #63 calls: descriptions and HQs, no NRC description; Bernhard an investor since 16 Oct" do
    load_seeds

    centrus = Organization.find_by!(slug: "centrus-energy")
    assert_match "enriched uranium", centrus.description
    assert_equal [ "Bethesda", "MD" ], [ centrus.hq_city, centrus.hq_state ]

    nrc = Organization.find_by!(slug: "us-nuclear-regulatory-commission")
    assert_nil nrc.description
    assert_equal [ "Rockville", "MD" ], [ nrc.hq_city, nrc.hq_state ]
    # Tosin reversed #63 on 16 Oct 2026: it owns Allied Power, a nuclear services company.
    assert_equal [ "venture_capital" ], Organization.find_by!(slug: "bernhard-capital-partners").roles.pluck(:key)
  end

  test "CFS and Google share one ARC facility, and Dominion owns only the site, so has no link to the plant" do
    load_seeds

    arc = Facility.find_by!(name: "Fall Line Fusion Power Station")
    links = arc.facility_relationships.includes(:organization).to_h { |link| [ link.organization.slug, link ] }
    assert_equal %w[commonwealth-fusion-systems google], links.keys.sort
    assert links["google"].offtakes_from?
    assert_match "leasing rights", links["commonwealth-fusion-systems"].description
  end

  test "ENTRA1's 2023 SEC quotes come off after the seed attaches its own sources" do
    load_seeds
    load Rails.root.join("db/data/20261022200000_entra1_drop_sec_evidence.rb")
    company = Organization.find_by!(slug: "entra1-energy")
    sec = Source.find_or_create_by!(url: Entra1DropSecEvidence::SOURCE_URL) { |source| source.source_kind = "web_page" }
    role = company.organization_roles.first
    [ company, role ].each { |fact| Evidence.create!(subject: fact, source: sec, quote: "ENTRA1 is a company from the filing", confidence: 0.9, found_by: "human") }

    Entra1DropSecEvidence.new(reason: "test").up

    assert_empty Evidence.where(source: sec, subject: [ company, role ])
    assert company.evidence.any?, "the company keeps its own site's quote"
    assert role.evidence.any?, "the role keeps its own site's quote"
    assert_nothing_raised { Entra1DropSecEvidence.new(reason: "test").up }
  end

  test "is safe to re-run" do
    load_seeds
    Role.find_by!(key: "fuel").update!(name: "Edited")

    assert_no_difference(COUNTED) { load_seeds }
    assert_equal "Fuel", Role.find_by!(key: "fuel").name
  end
end
