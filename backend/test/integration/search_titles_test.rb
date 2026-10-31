require "test_helper"
require_relative "../support/directory_builders"

# Titles and descriptions in the words people search with, built only from
# published facts (#290 categories, #291 plants, #292 companies). URLs don't
# change.
class SearchTitlesTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  def meta_description = css_select("meta[name='description']").first["content"]
  def og_description = css_select("meta[property='og:description']").first["content"]
  # The link-preview description: what company and plant pages said in their meta tag before Tosin's 29 Oct SEO
  # change (their meta now carries counts; see the SEO tests below).
  def description = og_description

  test "every category and tag page has a search title and a counted description that doesn't talk about sourcing" do
    (Category.all + Tag.all).each do |category|
      assert category.title.present?, category.key
      assert_operator category.title.length, :<=, 60, category.key
      assert_match(/\A11 /, category.description(11), category.key)
      assert_no_match(/source/i, category.description(11), category.key)
      assert_operator category.description(11).length, :<=, 160, category.key
    end
    assert_equal "Fusion energy companies in the US.", Tag.find("fusion").description(1)
    Tag.all.each { |tag| assert_operator "#{tag.title} | Nuclear Directory".length, :<=, 60, "#{tag.key}: the whole title" }
  end

  test "a tag page uses its search title and its count; the heading stays short" do
    fusion = technology("fusion", "Fusion")
    %w[Helion TAE].each { |name| cite!(company(name, techs: [ fusion ])) }

    get companies_path(tag: "fusion")

    assert_select "title", "Fusion energy companies in the US | Nuclear Directory"
    assert_select "h1", /Fusion/
    assert_equal "2 fusion energy companies in the US.", description
    assert_equal description, og_description
  end

  test "an SMR tag page is titled like the search and opens from the tag under a company's name (#606)" do
    smr = technology("smr", "Small modular reactor")
    kairos = cite!(company("Kairos Power", techs: [ smr ], roles: [ role("enrichment") ]))
    cite!(company("NuScale", techs: [ smr ]))

    get companies_path(tag: "smr")
    assert_select "title", "SMR companies in the US | Nuclear Directory"
    assert_equal "2 small modular reactor (SMR) companies in the US.", description
    assert_select ".nd-pagehead__square svg", minimum: 1, message: "the tag page heading carries the tag's icon square, like a category page"

    cite!(company("Isotope Co", roles: [ role("isotopes") ]))
    get companies_path(tag: "isotopes")
    assert_select ".nd-pagehead__square svg", minimum: 1, message: "a role tag shows its category's icon"

    get company_path(slug: kairos.slug)
    assert_select ".nd-pagehead__tags a.nd-tag--link[href=?]", companies_path(tag: "smr"), /Small modular reactor/
    assert_select ".nd-pagehead__tags a.nd-tag--link[href=?]", companies_path(tag: "enrichment")
    assert_select ".nd-pagehead__tags a.nd-tag--link .nd-tag__go svg", minimum: 1, message: "a linked tag shows its chevron at rest"
    assert_select ".nd-pagehead__tags span.nd-tag .nd-tag__go", 0

    get sitemap_path
    assert_includes response.body, companies_url(tag: "smr")
    assert_not_includes response.body, companies_url(tag: "conversion"), "a tag with no company isn't in the sitemap"
  end

  test "a company with no one-line description is described by its plants, never the generic line (#247)" do
    utility = cite!(company("Alabama Power", city: "Birmingham", state: "AL", roles: [ role("utility") ]))
    %w[Farley Hatch Vogtle].each { |name| cite!(link(utility, "owns", cite!(plant(name, facility_type: "power_reactor")))) }
    cite!(link(utility, "operates", Facility.find_by!(name: "Farley")))

    get company_path(slug: utility.slug)

    assert_select "title", "Alabama Power: plants | Nuclear Directory"
    assert_equal "Alabama Power is a utility in Birmingham, AL, with 3 plants.", meta_description
    assert_equal "Alabama Power: Utility in Birmingham, AL. Owns Farley and 2 other plants. Operates Farley.", description
    assert_equal description, og_description
    assert_no_match(/Plants, sites and deals/, description)
  end

  test "a long description is cut at a word under 160 characters, and the legal name is added when it fits" do
    long = cite!(company("Holtec", description: "Designs and builds spent fuel storage casks and the SMR-300 small modular reactor, " \
      "and decommissions shut-down plants across the United States and abroad.", legal_name: "Holtec International"))
    short = cite!(company("GNF-A", description: "Makes nuclear fuel.", legal_name: "Global Nuclear Fuel-Americas, LLC"))

    get company_path(slug: long.slug)
    assert_operator description.length, :<=, 160
    assert_match(/\AHoltec: Designs and builds/, description)

    get company_path(slug: short.slug)
    assert_equal "GNF-A: Makes nuclear fuel. Legal name: Global Nuclear Fuel-Americas, LLC.", description
  end

  test "a fusion developer with investors says so in its title and description" do
    fusion = technology("fusion", "Fusion")
    helion = cite!(company("Helion Energy", roles: [ role("reactor_vendor") ], techs: [ fusion ], description: "Develops fusion power plants."))
    cite!(link(cite!(company("Lightspeed")), "invests_in", helion))

    get company_path(slug: helion.slug)

    assert_select "title", "Helion Energy: investors | Nuclear Directory"
    assert_match(/\AHelion Energy: Develops fusion power plants\. 1 investor\.\z/, meta_description)
    assert_equal "Helion Energy: Develops fusion power plants. Investors include Lightspeed.", description
  end

  test "an ended deal isn't present tense, and an unpublished plant type isn't called a plant" do
    supplier = cite!(company("Old Supplier", roles: [ role("fuel") ], description: "Made fuel."))
    cite!(link(supplier, "supplies", cite!(company("Past Customer")))).update!(ended_on: Date.new(2020, 1, 1))
    owner = cite!(company("Owner Co", description: "Owns things."))
    [ "Unknown One", "Unknown Two" ].each { |name| cite!(link(owner, "owns", plant(name, facility_type: "power_reactor"))) }

    get company_path(slug: supplier.slug)
    assert_no_match(/Supplies/, description)

    get company_path(slug: owner.slug)
    assert_match(/and 1 other site\./, description)
  end

  test "a mine or fuel plant among them makes them sites, not plants" do
    miner = cite!(company("Energy Fuels", roles: [ role("fuel") ], description: "Produces uranium."))
    cite!(link(miner, "owns", cite!(plant("Pinyon Plain Mine", facility_type: "uranium_mine"))))
    cite!(link(miner, "owns", cite!(plant("White Mesa Mill", facility_type: "mill"))))

    get company_path(slug: miner.slug)

    assert_equal "Energy Fuels: Produces uranium. Owns Pinyon Plain Mine and 1 other site.", description
  end

  test "the title's role is the one the company's category is for" do
    coolant = role("coolant")
    kairos = cite!(company("Kairos Power", roles: [ role("molten_salt_coolant", parent: coolant), role("reactor_vendor") ]))

    get company_path(slug: kairos.slug)

    assert_select "title", "Kairos Power | Nuclear Directory", "no section the page has, none claimed"
  end

  test "a grant or award isn't an investment, and an ended or future link isn't present tense" do
    fusion = technology("fusion", "Fusion")
    helion = cite!(company("Helion Energy", roles: [ role("reactor_vendor") ], techs: [ fusion ], description: "Develops fusion power plants."))
    cite!(link(cite!(company("US Department of Energy")), "funds", helion))
    utility = cite!(company("Old Utility", roles: [ role("utility") ]))
    cite!(link(utility, "operates", cite!(plant("Retired Station")))).update!(ended_on: Date.new(2020, 1, 1))
    cite!(link(utility, "owns", cite!(plant("Future Station")))).update!(started_on: Date.current + 1.year)

    get company_path(slug: helion.slug)
    assert_no_match(/Investors/, description)
    assert_no_match(/investors/, css_select("title").text)

    get company_path(slug: utility.slug)
    assert_no_match(/Operates|Owns/, description)
  end

  test "a filtered category describes what it lists, not the whole category" do
    fusion = technology("fusion", "Fusion")
    cite!(company("Helion", techs: [ fusion ], state: "WA"))
    %w[TAE Zap].each { |name| cite!(company(name, techs: [ fusion ], state: "CA")) }

    get companies_path(tag: "fusion", state: "CA")

    assert_equal "2 fusion energy companies in the US.", description
  end

  test "a long company name drops the suffix first, then sections, to keep the title within 60 characters" do
    name = "Northern States Power Company Minnesota Generation"
    cite!(company(name, roles: [ role("utility") ])).then { |org| cite!(link(org, "owns", cite!(plant("Prairie Island")))) }

    get company_path(slug: Organization.find_by!(name:).slug)

    assert_select "title", "#{name}: sites", "a plant with no published facts is a site, as in the description"
    assert_operator css_select("title").text.length, :<=, 60
  end

  test "a company's title and meta name only the sections the page has: partners, customers, investors, plants" do
    oklo = cite!(company("Oklo", description: "Develops advanced fission power plants."))
    cite!(link(cite!(company("Lightspeed")), "invests_in", oklo))
    cite!(link(oklo, "supplies", cite!(company("Buyer Co"))))
    cite!(link(oklo, "owns", cite!(plant("Aurora", facility_type: "power_reactor"))))

    get company_path(slug: oklo.slug)

    assert_select "title", "Oklo: partners, customers, investors and plants", "too long with the suffix, so the suffix goes"
    assert_operator css_select("title").text.length, :<=, 60
    assert_match(/\AOklo: Develops advanced fission power plants\. 1 plant, 1 deal, 1 investor\.\z/, meta_description)
    assert_operator meta_description.length, :<=, 160
  end

  test "a plant's meta never runs past 160 characters, and a framework offtake isn't a deal" do
    long = cite!(plant("A Very Long Plant Name " * 6, facility_type: "power_reactor", status: "operating", city: "Somewhere", state: "TX"))
    cite!(link(cite!(company("Owner Co")), "owns", long))

    get plant_path(slug: long.slug)
    assert_operator meta_description.length, :<=, 160
  end

  test "a plant's title names its town and state, and owners and operator only when they're published (#291)" do
    owned = cite!(plant("Arkansas Nuclear One", facility_type: "power_reactor", status: "operating", city: "Russellville", state: "AR"))
    cite!(link(cite!(company("Entergy Arkansas")), "owns", owned))
    bare = cite!(plant("Lone Site", facility_type: "uranium_mine", city: "Crownpoint", state: "NM"))

    get plant_path(slug: owned.slug)
    assert_select "title", "Arkansas Nuclear One: owners | Nuclear Directory"
    assert_match(/\AArkansas Nuclear One: .*Russellville, Arkansas\. 1 owner\.\z/, meta_description)
    assert_match(/in Russellville, Arkansas\./, description)

    get plant_path(slug: bare.slug)
    assert_select "title", "Lone Site | Nuclear Directory"
  end
end
