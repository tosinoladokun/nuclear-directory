require "test_helper"
require_relative "../support/directory_builders"

# Internal links for indexing (#606, Outcome 30 Nov): the biggest tag lists in every footer, every non-empty tag on the
# home page, and up to five similar companies on a company page. A link never leads to an empty list.
class InternalLinksTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    smr = technology("smr", "Small modular reactor")
    fusion = technology("fusion", "Fusion")
    vendor = role("reactor_vendor")
    @oklo = cite!(company("Oklo", roles: [ vendor ], techs: [ smr ], description: "Develops advanced fission."))
    %w[Aardvark Badger Cheetah Dingo Eagle Ferret].each { |name| cite!(company(name, roles: [ vendor ], techs: [ smr ])) }
    cite!(company("Helion", roles: [ vendor ], techs: [ fusion ]))
  end

  test "the footer and the home page link the tag lists that have companies, and no empty one" do
    get companies_path
    assert_select "footer nav[aria-label=Topics] .nd-footer__topics-label", "Topics:"
    assert_select "footer nav[aria-label=Topics] a[href=?]", companies_path(tag: "smr"), "Small modular reactors"
    assert_select "footer nav[aria-label=Topics] a[href=?]", companies_path(tag: "fusion")
    assert_select "footer nav[aria-label=Topics] a[href=?]", companies_path(tag: "conversion"), count: 0

    get root_path
    assert_select ".nd-home__topics > p.nd-label", "Topics"
    assert_select ".nd-home__topics nav[aria-labelledby=home-topics] a.nd-chip[href=?]", companies_path(tag: "smr"), /Small modular reactors\s+7/
    assert_select ".nd-home__topics a.nd-chip[href=?]", companies_path(tag: "conversion"), count: 0
  end

  test "a company page lists up to five similar companies: its tag first, then its category, never itself" do
    get company_path(slug: @oklo.slug)

    assert_select "#similar-heading", /Similar companies\s*5/, "the shared section head with its count"
    assert_select "#similar a.nd-line .nd-line__mark .nd-catsq", minimum: 5, message: "the shared row with the category square"
    body = response.body
    assert_operator body.index('id="similar"'), :>, body.index("nd-company__end"), "after the record's own actions (sources, cite, report), on every width"
    links = css_select("#similar a.nd-line").map { |a| a["href"] }
    assert_equal 5, links.size
    assert_not_includes links, company_path(slug: @oklo.slug)
    assert_equal links.uniq, links
    assert_includes links.join, "aardvark"

    get company_path(slug: Organization.find_by!(name: "Helion").slug)
    assert_select "#similar a.nd-line", 5, "Helion shares only the category: the five most connected of it, not itself"
    assert_select "#similar a.nd-line[href=?]", company_path(slug: Organization.find_by!(name: "Helion").slug), count: 0
  end

  test "a company with nobody similar has no block" do
    lone = cite!(company("Lone Utility", roles: [ role("utility") ]))
    get company_path(slug: lone.slug)
    assert_select "#similar", 0
  end

  test "an SMR-only company's similar list reaches its parent tag (fission) once SMR peers run out" do
    fission = technology("fission", "Fission")
    Technology.find_by!(key: "smr").update!(parent: fission)
    lone = cite!(company("Lone Smr Co", techs: [ Technology.find_by!(key: "smr") ]))
    peer = cite!(company("Fission Only Peer", techs: [ fission ]))

    held = SimilarCompanies.new(CompanyProfile.new(lone)).send(:held_tags).map(&:key)
    assert_includes held, "smr"
    assert_includes held, "fission", "the parent's tag list holds it too"
    assert_includes SimilarCompanies.new(CompanyProfile.new(lone)).send(:pools).flat_map { |listing| listing.companies.to_a }, peer, "once the SMR peers run out, the fission list follows"
  end
end
