require "test_helper"
require_relative "../support/directory_builders"

class CompanyPageTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    @press = Source.create!(url: "https://kairospower.com/news/google", title: "Google and Kairos Power partner",
      source_kind: "web_page", published_on: Date.new(2024, 10, 14))
    @doe_page = Source.create!(url: "https://www.energy.gov/haleu", source_kind: "web_page")

    @kairos = company("Kairos Power", city: "Alameda", state: "CA", roles: [ role("reactor_vendor") ],
      techs: [ technology("smr", "Small modular reactor") ], aliases: [ "Kairos Power, LLC", "Kairos" ],
      website: "https://kairospower.com", description: "Develops salt-cooled reactors.", verified_at: Time.zone.parse("2026-10-09"))
    @google = company("Google", roles: [ role("data_center_offtaker") ])
    @doe = company("US Department of Energy")
    @ghost = company("Ghost Partner", verified: false)
    cite!(@kairos, @google, @doe, source: @press)

    deal = link(@google, "offtake_with", @kairos)
    deal.update!(description: "500 MW by 2035.")
    # The decision's date, set as test data (a real date only changes with a named decision).
    deal.update_column(:verified_at, Time.zone.parse("2026-10-09"))
    deal.evidence.create!(source: @press, quote: "Kairos Power and Google have signed", found_by: "human", confidence: 1)
    link(@doe, "supplies", @kairos).evidence.create!(source: @doe_page, found_by: "human", confidence: 0.8)
    cite!(link(@ghost, "invests_in", @kairos), link(@kairos, "funds", @google, verified: false))

    @hermes = cite!(plant("Hermes", facility_type: "research_reactor", status: "under_construction", city: "Oak Ridge", state: "TN"), source: @press)
    link(@kairos, "owns", @hermes).evidence.create!(source: @press, found_by: "human", confidence: 1)
    hidden = plant("Hidden Site", verified: false)
    cite!(link(@kairos, "owns", hidden))
  end

  test "a verified company's page shows its facts" do
    get company_path(slug: "kairos-power")

    assert_response :success
    assert_select "title", "Kairos Power: reactor developer, plants and deals · Nuclear Directory"
    assert_select "main", 1
    assert_select "h1#profile-name", "Kairos Power"
    assert_select ".nd-profile__desc", /Develops salt-cooled reactors./
    assert_select ".nd-tag", "Reactor designer"
    assert_select ".nd-tag", "Small modular reactor"
    assert_select ".nd-crumbs a[href=?]", "/companies?category=reactor-developers", text: "Developers"
  end

  test "deals read left to right, link the other company, and carry sources" do
    get company_path(slug: "kairos-power")

    assert_select "#deals-heading small", "2"
    assert_select ".nd-factrow", text: /Google\s+offtakes from\s+Kairos Power/ do
      assert_select "a[href='/companies/google']", "Google"
      assert_select ".nd-factrow__detail", "500 MW by 2035."
      assert_select ".nd-quote", "“Kairos Power and Google have signed”"
      assert_select "a.nd-src[href='#source-1']", /kairospower.com · checked 2026-10-09/ do
        # On a narrow screen the date wraps as one piece (#90).
        assert_select "span.nd-src__checked", "· checked 2026-10-09"
      end
      assert_select ".nd-conf", /High/
    end
    assert_select ".nd-factrow", text: /US Department of Energy\s+supplies\s+Kairos Power/
  end

  test "unverified partners, deals and plants never appear" do
    get company_path(slug: "kairos-power")

    assert_select "body", text: /Ghost Partner/, count: 0
    assert_select ".nd-factrow", text: /funds/, count: 0
    assert_select "body", text: /Hidden Site/, count: 0
  end

  test "unpublished facts, partners and plants disappear from the page, and come back when republished" do
    get company_path(slug: "kairos-power")
    assert_select "body", text: /Google/
    assert_select "body", text: /Hermes/

    @google.unpublish!(by: "human:test")
    @hermes.unpublish!(by: "human:test")
    @kairos.organization_roles.sole.unpublish!(by: "human:test")
    get company_path(slug: "kairos-power")

    assert_select "body", text: /Google/, count: 0
    assert_select "body", text: /Hermes/, count: 0
    assert_select "body", text: /Reactor designer/, count: 0

    @google.verify!(by: "human:test")
    get company_path(slug: "kairos-power")
    assert_select "body", text: /Google/

    @kairos.unpublish!(by: "human:test")
    get company_path(slug: "kairos-power")
    assert_response :not_found
  end

  test "a plant's type, status and place show beside a link only when the plant has its own source" do
    bare = plant("Bare Reactor", facility_type: "power_reactor", status: "operating", city: "Nowhere", state: "OR")
    cite!(link(@kairos, "operates", bare))
    get company_path(slug: "kairos-power")

    assert_select ".nd-factrow", text: /Kairos Power\s+operates\s+Bare Reactor/ do
      assert_select ".nd-factrow__detail", count: 0
    end
  end

  test "plants and sites link to the plant page" do
    get company_path(slug: "kairos-power")

    assert_select ".nd-factrow", text: /Kairos Power\s+owns\s+Hermes/ do
      assert_select "a[href='/plants/hermes']", "Hermes"
      assert_select ".nd-factrow__detail", "Test reactor · Under construction · Oak Ridge, TN"
    end
  end

  test "sources are numbered once, in reading order" do
    get company_path(slug: "kairos-power")

    assert_select "#sources-heading small", "2"
    assert_select "li#source-1 a[href='https://kairospower.com/news/google']", "Google and Kairos Power partner"
    assert_select "li#source-2 small", "energy.gov"
  end

  test "on touch screens a source chip opens a sheet; without JavaScript it still jumps to the list" do
    get company_path(slug: "kairos-power")

    assert_select "[data-controller=source-sheet][data-action='click@document->source-sheet#open']" do
      assert_select "dialog.nd-sheet[aria-labelledby=source-sheet-title]" do
        assert_select "h2#source-sheet-title", /Source/
        assert_select "button[type=button][data-action='source-sheet#close']", "Close source details"
      end
    end
    assert_select ".nd-factrow a.nd-src[href='#source-1']"
    assert_select ".nd-factrow .nd-quote[data-source-number='1']", "“Kairos Power and Google have signed”"
  end

  test "key facts" do
    get company_path(slug: "kairos-power")

    assert_select ".nd-overview dt", text: "Website"
    # #200: the Website link carries the referral UTM so companies see the
    # visit in their own analytics. The href starts with the website, with
    # utm_source / utm_medium / utm_campaign on the query string.
    assert_select ".nd-overview dd a[href^='https://kairospower.com?']", text: "kairospower.com"
    link = css_select(".nd-overview dd a[href^='https://kairospower.com?']").first
    params = URI.decode_www_form(URI.parse(link["href"]).query).to_h
    assert_equal "nuclear-directory", params["utm_source"]
    assert_equal "referral", params["utm_medium"]
    assert_equal "company-page", params["utm_campaign"]
    assert_select ".nd-overview dd", text: /\AKairos\z/
    assert_select ".nd-overview dd", text: /\AAlameda, CA\z/
    # The record's sources show once, under the facts, and name no fact.
    assert_select ".nd-overview p.nd-overview__sources", text: /\AAbout this company: sources\s*1\z/ do
      assert_select "a.nd-src[href='#source-1']"
    end
    assert_select ".nd-overview dt", text: "Founded", count: 0
    assert_select ".nd-overview__foot", /checked 2026-10-09/
  end

  test "a parent company shows in the key facts, not as a deal" do
    parent = company("Southern Company")
    cite!(link(@kairos, "subsidiary_of", parent))
    get company_path(slug: "kairos-power")

    assert_select ".nd-overview dt", "Parent company"
    assert_select ".nd-overview dd a[href='/companies/southern-company']", "Southern Company"
    assert_select ".nd-factrow", text: /subsidiary/, count: 0
  end

  test "a general role is left out when a more specific one under it is there" do
    coolant = role("coolant")
    [ coolant, role("molten_salt", parent: coolant) ].each do |r|
      cite!(OrganizationRole.create!(organization: @kairos, role: r, **verification(true)))
    end
    get company_path(slug: "kairos-power")

    assert_select ".nd-tag", text: "Molten salt coolant"
    assert_select ".nd-tag", text: "Coolant", count: 0
  end

  test "a hidden general role's sources aren't shown" do
    coolant = role("coolant")
    general = OrganizationRole.create!(organization: @kairos, role: coolant, **verification(true))
    general.evidence.create!(source: Source.create!(url: "https://example.com/coolant", source_kind: "web_page"), found_by: "human", confidence: 1)
    cite!(OrganizationRole.create!(organization: @kairos, role: role("molten_salt", parent: coolant), **verification(true)))
    get company_path(slug: "kairos-power")

    assert_select ".nd-tag", text: "Molten salt coolant"
    assert_select "body", text: /example\.com/, count: 0
  end

  test "a unit under a rejected site isn't linked" do
    rejected = Facility.create!(name: "Rejected Station", verification_status: "rejected", verified_by: "human:test")
    cite!(link(@kairos, "owns", cite!(plant("Rejected Unit", parent: rejected))))
    get company_path(slug: "kairos-power")

    assert_select "body", text: /Rejected/, count: 0
  end

  test "key facts come first in the page, before deals" do
    get company_path(slug: "kairos-power")

    assert_select ".nd-columns--profile > :first-child.nd-columns__side"
  end

  test "facts without a source aren't shown" do
    bare = company("Bare Co", city: "Austin", state: "TX", roles: [ role("utility") ], website: "https://bare.example", description: "Runs plants.")
    link(bare, "supplies", @kairos)
    get company_path(slug: "bare-co")

    assert_response :success
    assert_select "body", text: /Runs plants|Austin|bare\.example|Kairos/, count: 0
    assert_select ".nd-tag", count: 0
    assert_select ".nd-gaps li", text: "One-line description"
    assert_select ".nd-gaps li", text: "Headquarters"
  end

  test "a company with only an invests-in deal gets the Investors breadcrumb" do
    backer = cite!(company("Backer Fund"))
    cite!(link(backer, "invests_in", @kairos))
    get company_path(slug: "backer-fund")

    assert_select ".nd-crumbs a[href=?]", "/companies?category=investors", text: "Investors"
  end

  test "every bucket the company is in is listed in its key facts, each linked (#281)" do
    westinghouse = cite!(company("Westinghouse", roles: [ Role.find_by(key: "reactor_vendor") || role("reactor_vendor"), role("reactor_services") ]))
    cite!(link(westinghouse, "invests_in", @kairos))
    get company_path(slug: westinghouse.slug)

    assert_select ".nd-overview dt", "Type"
    assert_equal [ "Developers", "Services and engineering", "Investors" ], css_select(".nd-overview ul.nd-bucketchips li .nd-bucketchip__full").map { |label| label.text.strip }
    assert_select ".nd-overview a.nd-bucketchip.nd-bucket--reactor-developers[href=?] svg", "/companies?category=reactor-developers"
    assert_select ".nd-overview a.nd-bucketchip.nd-bucket--services[href=?][aria-label=?]", "/companies?category=services", "Services and engineering" do
      assert_select ".nd-bucketchip__short[aria-hidden=true]", "Services", "the short label where the full one can't fit"
    end
    assert_select ".nd-overview a.nd-bucketchip.nd-bucket--investors[href=?]", "/companies?category=investors"
    assert_select ".nd-crumbs a[href=?]", "/companies?category=reactor-developers", text: "Developers"
  end

  test "a hidden invests-in deal doesn't make a company an investor" do
    backer = cite!(company("Quiet Fund"))
    link(backer, "invests_in", @kairos)
    get company_path(slug: "quiet-fund")

    assert_select ".nd-crumbs a", count: 0
  end

  test "missing must-have fields are listed, not guessed" do
    get company_path(slug: "google")

    assert_select ".nd-gaps li", text: "One-line description"
    assert_select ".nd-gaps li", text: "Headquarters"
    assert_select ".nd-profile__desc", count: 0
  end

  test "long lists collapse behind Show all" do
    (CompanyProfile::VISIBLE_ITEMS + 1).times do |i|
      cite!(link(company("Supplier #{i}"), "supplies", @kairos))
    end
    get company_path(slug: "kairos-power")

    assert_select "#deals-heading ~ ul.nd-list > li", CompanyProfile::VISIBLE_ITEMS
    assert_select "details.nd-more summary .nd-more__open", "Show all #{CompanyProfile::VISIBLE_ITEMS + 3} deals"
    assert_select "details.nd-more summary .nd-more__close", "Show fewer deals"
  end

  test "link preview tags" do
    get company_path(slug: "kairos-power")

    assert_select "meta[property='og:title'][content='Kairos Power']"
    line = "Kairos Power: Develops salt-cooled reactors. Owns Hermes."
    assert_select "meta[property='og:description'][content=?]", line
    assert_select "meta[name=description][content=?]", line
    assert_select "link[rel=canonical][href=?]", "http://www.example.com/companies/kairos-power"
  end

  test "a renamed or merged company's old address moves to its page" do
    @kairos.update!(slug: "kairos")
    get company_path(slug: "kairos-power")
    assert_redirected_to company_path(slug: "kairos")
    assert_response :moved_permanently

    merged = company("Kairos Power USA")
    Directory::FactWriter.merge_organization(from_id: merged.id, into_id: @kairos.id, by: "human:tosin")
    get company_path(slug: merged.slug)
    assert_redirected_to company_path(slug: "kairos")
  end

  test "a hidden company's old address isn't redirected, and merges stay one hop" do
    hidden = company("Quiet Co", verified: false)
    hidden.update!(slug: "quiet-co-renamed")
    get company_path(slug: "quiet-co")
    assert_response :not_found

    first = company("Kairos One")
    second = company("Kairos Two")
    Directory::FactWriter.merge_organization(from_id: first.id, into_id: second.id, by: "human:tosin")
    Directory::FactWriter.merge_organization(from_id: second.id, into_id: @kairos.id, by: "human:tosin")
    get company_path(slug: first.slug)
    assert_redirected_to company_path(slug: @kairos.slug)
  end

  test "an unverified or unknown company is not found" do
    get company_path(slug: "ghost-partner")
    assert_response :not_found

    get company_path(slug: "nobody")
    assert_response :not_found
  end
end
