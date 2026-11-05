require "test_helper"
require_relative "../support/directory_builders"

# Internal links for indexing (#606, Outcome 30 Nov): up to five similar companies on a company page. (The Topics chips and
# footer links were cut on 2 Nov.)
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

  test "no Topics on the home page or in the footer (Tosin, 2 Nov): only Similar companies adds links" do
    get root_path
    assert_select ".nd-home__topics", 0
    assert_select "footer a[href*='tag=']", 0
    assert_select "footer .nd-footer__label--topics", 0
    get companies_path
    assert_select "footer a[href*='tag=']", 0
  end

  test "a company page lists up to five similar companies: its tag first, then its category, never itself" do
    get company_path(slug: @oklo.slug)

    assert_select "#similar-heading", /\ASimilar companies\s*\z/, "the shared section head, with no count (it is nearly always the limit)"
    assert_select "#similar a.nd-line.nd-line--bare", minimum: 5, message: "the shared bare company row, as the category and tag lists use (no mark by design, Design 31 Oct)"
    assert_select "#similar .nd-catsq", 0
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

  test "a similar company's place shows only when its record has a source, as on its own page" do
    utility = role("utility")
    mine = cite!(company("Quartz Home", roles: [ utility ], city: "Austin", state: "TX"))
    unsourced = company("Zebra Unsourced", roles: [ utility ], city: "Nowhere", state: "ND")
    unsourced.organization_roles.each { |link| link.evidence.create!(source: default_source, found_by: "human", confidence: 1) } # the role is sourced, its own record is not
    sourced = cite!(company("Yak Sourced", roles: [ utility ], city: "Somewhere", state: "SD"))
    get company_path(slug: mine.slug)

    assert_select "#similar a[href=?]", company_path(slug: sourced.slug), text: /Somewhere, SD/
    assert_select "#similar a[href=?]", company_path(slug: unsourced.slug), text: /Zebra Unsourced/
    assert_no_match "Nowhere", css_select("#similar").text
  end
end
