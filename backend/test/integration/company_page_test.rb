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
    assert_select "h1.nd-pagehead__name", "Kairos Power"
    assert_select ".nd-pagehead__about", "Develops salt-cooled reactors."
    assert_select ".nd-pagehead__about .nd-src", 0, "the summary carries no source marks"
    assert_select ".nd-tag", "Reactor designer"
    assert_select ".nd-tag", "Small modular reactor"
    assert_select ".nd-crumbs a[href=?]", "/companies?category=reactor-developers", text: "Developers"
  end

  test "a deal is one line: the other company, the verb, the date and a source mark; it opens to its details" do
    get company_path(slug: "kairos-power")

    assert_select "#deals-heading .nd-sechead__count", "2"
    assert_select ".nd-crow", text: /Google offtakes from Kairos Power/ do
      assert_select "button.nd-crow__line[aria-expanded=false][aria-controls]"
      assert_select ".nd-crow__more[hidden]" do
        assert_select "p", "500 MW by 2035."
        assert_select ".nd-quote", "“Kairos Power and Google have signed”"
        assert_select "a.nd-src[href='#source-1']", /kairospower.com · checked 2026-10-09/
        assert_select ".nd-conf", /High/
      end
      assert_select "a.nd-mark[href='#source-1'][aria-label='1 source']"
      assert_select "a", text: "Report a correction", count: 0
    end
    assert_select ".nd-crow", text: /US Department of Energy supplies Kairos Power/
  end

  test "a deal row's short line comes from stored terms, else the link's sourced phrase, else nothing" do
    offtake = Relationship.find_by!(from_organization: @google, to_organization: @kairos)
    term = DealTerm.create!(link: offtake, term_type: "offtake", capacity_mw: 5000, agreement: "framework", ends_on: Date.new(2039, 1, 1),
      signed_on: Date.new(2026, 3, 1), **verification(true))
    term.evidence.create!(source: @doe_page, quote: "5 GW framework", found_by: "human", confidence: 1)
    DealTerm.create!(link: offtake, term_type: "offtake", capacity_mw: 1, agreement: "ppa", signed_on: Date.new(2030, 1, 1), **verification(true)) # no source: never shown
    supply = Relationship.find_by!(from_organization: @doe, to_organization: @kairos)
    supply.update!(short_phrase: "LEU and HALEU enrichment")
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow", text: /Google offtakes from Kairos Power/ do
      assert_select ".nd-crow__what", "5 GW framework by 2039"
      assert_select "time.nd-crow__date[datetime='2026-03-01']", "Mar 2026"
      assert_select "a.nd-mark[data-sources='1,2'][data-checked='2026-10-09']", 1, "the term's own source counts too, and the mark carries the checked date"
      assert_select ".nd-crow__more a[href='/companies/google']", "View Google", "the toggle is a button; the company is one click inside"
    end
    assert_select "li#source-2 small", "energy.gov", "a term's source is in the page's numbered list"
    assert_select ".nd-crow", text: /US Department of Energy supplies/ do
      assert_select ".nd-crow__what", "LEU and HALEU enrichment"
    end
    plain = company("Plain Partner")
    cite!(link(plain, "supplies", @kairos))
    get company_path(slug: "kairos-power")
    assert_select ".nd-crow", text: /Plain Partner supplies/ do
      assert_select ".nd-crow__what", 0
    end
  end

  test "a company with no evidence of its own shows no country as its headquarters" do
    bare = company("Bare Abroad Co", city: nil)
    bare.update!(country_code: "FR")
    cite!(link(bare, "supplies", @kairos))
    get company_path(slug: "bare-abroad-co")

    assert_response :success
    assert_select ".nd-glance dt", text: "Headquarters", count: 0
    assert_select "body", text: /France/, count: 0
  end

  test "a plant link's role is named as the public wording does" do
    designer = plant("Designer Site", facility_type: "power_reactor")
    cite!(link(@kairos, "vendor_for", designer))
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow--plant", text: /Designer Site\s*reactor developer/
  end

  test "deals are newest first" do
    old = cite!(link(company("Old Partner"), "supplies", @kairos))
    old.update!(started_on: Date.new(2019, 1, 1))
    new = cite!(link(company("New Partner"), "supplies", @kairos))
    new.update!(started_on: Date.new(2026, 6, 1))
    get company_path(slug: "kairos-power")

    names = css_select(".nd-crow .nd-crow__who").map { |el| el.text }
    assert_operator names.index { |n| n.include?("New Partner") }, :<, names.index { |n| n.include?("Old Partner") }
  end

  test "unverified partners, deals and plants never appear" do
    get company_path(slug: "kairos-power")

    assert_select "body", text: /Ghost Partner/, count: 0
    assert_select ".nd-crow", text: /funds/, count: 0
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

  test "a plant's status and place show on its row only when the plant has its own source" do
    bare = plant("Bare Reactor", facility_type: "power_reactor", status: "operating", city: "Nowhere", state: "OR")
    cite!(link(@kairos, "operates", bare))
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow--plant", text: /Bare Reactor/ do
      assert_select ".nd-st", 0
      assert_select ".nd-crow__place", 0
    end
  end

  test "plants and sites link to the plant page, with status, place and a source mark" do
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow--plant", text: /Hermes/ do
      assert_select "a[href='/plants/hermes']", "Hermes"
      assert_select ".nd-st", /Under construction/
      assert_select ".nd-crow__place", "Oak Ridge, TN"
      assert_select "a.nd-mark"
    end
    assert_select "#plants-heading .nd-sechead__note", "· as owner", "every row shares the role, so the heading carries it"
  end

  test "sources are numbered once, in reading order" do
    get company_path(slug: "kairos-power")

    assert_select "li#source-1 a[href='https://kairospower.com/news/google']", "Google and Kairos Power partner"
    assert_select "li#source-2 small", "energy.gov"
  end

  test "a source mark opens its sources in the sheet; the list sits behind the quiet line" do
    get company_path(slug: "kairos-power")

    assert_select "[data-controller=source-sheet][data-action='click@document->source-sheet#open']" do
      assert_select "dialog.nd-sheet[aria-labelledby=source-sheet-title]" do
        assert_select "h2#source-sheet-title", /Source/
        assert_select "button[type=button][data-action='source-sheet#close']", "Close source details"
      end
      assert_select "ol.nd-sources#sources:not([hidden])", 1, "in the page open, so links and no-JavaScript visitors land; the script folds it"
    end
    assert_select ".nd-crow a.nd-mark[href='#source-1'][data-sources='1']"
    assert_select ".nd-crow__more .nd-quote[data-source-number='1']", "“Kairos Power and Google have signed”"
  end

  test "the quiet line is the page's last line: sources, cite this page, one Report a correction" do
    get company_path(slug: "kairos-power")

    assert_select "nav.nd-quiet" do
      assert_select "button[data-panel=sources][aria-expanded=false]", /2\s+sources/
      assert_select "button[data-panel=cite]", /Cite this page/
      assert_select "a[href^='/corrections/new']", /Report a correction/
    end
    assert_select "#cite .nd-cite", /Nuclear Directory\. “Kairos Power\.” http.*\/companies\/kairos-power\. Accessed/
    assert_select "#cite button[data-action='copy#copy']", "Copy"
    assert_select "a", text: "Report a correction", count: 1
    assert_select ".nd-badge--verified, .nd-gaps", 0
  end

  test "schema.org JSON-LD states the page's facts and lists its sources as citations (#185)" do
    get company_path(slug: "kairos-power")

    scripts = css_select("script[type='application/ld+json']")
    assert_equal 1, scripts.size
    graph = JSON.parse(scripts.first.text).fetch("@graph")
    page, org = graph
    assert_equal "http://www.example.com/companies/kairos-power", page["url"]
    assert_equal "2026-10-09", page["dateModified"]
    assert_equal org["@id"], page.dig("mainEntity", "@id")
    assert_equal "Kairos Power", org["name"]
    assert_equal "Develops salt-cooled reactors.", org["description"]
    assert_equal "https://kairospower.com", org["url"]
    assert_equal({ "@type" => "PostalAddress", "addressLocality" => "Alameda", "addressRegion" => "CA" }, org["address"], "no country: the profile holds none")
    assert_includes org["alternateName"], "Kairos"
    assert_includes page["citation"].map { |c| c["url"] }, "https://kairospower.com/news/google"
    press = page["citation"].find { |c| c["url"] == "https://kairospower.com/news/google" }
    assert_equal [ "Google and Kairos Power partner", "2024-10-14" ], press.values_at("name", "datePublished")
    assert_equal page["citation"].size, css_select("ol.nd-sources li").size, "every source on the page is a citation"
    assert_not_includes response.body, "Ghost Partner", "an unpublished company is nowhere in the page, JSON-LD included"
  end

  test "a name with markup cannot end the JSON-LD script" do
    @kairos.update!(legal_name: "</script><script>alert(1)</script>")
    get company_path(slug: "kairos-power")

    assert_equal 1, css_select("script[type='application/ld+json']").size
    assert_not_includes response.body, "</script><script>alert(1)"
  end

  test "a company with both roles shows both role labels by its name, and only there (the Developers list shows none)" do
    designer = Role.find_or_create_by!(key: "reactor_vendor") { |role| role.name = "Reactor vendor" }
    developer = Role.find_or_create_by!(key: "project_developer") { |role| role.name = "Project developer" }
    both = cite!(company("Both Roles Holdings", roles: [ designer, developer ]))
    get company_path(slug: both.slug)

    assert_equal [ "Project developer", "Reactor designer" ], css_select(".nd-tag").map { |el| el.text.strip }.sort, "both role labels, in the tag row under the name"

    get companies_path(category: "reactor-developers")
    assert_select ".nd-listrow .nd-tag", 0
  end

  test "key facts: the value first, its label under it, no source marks or verified badge" do
    get company_path(slug: "kairos-power")

    assert_select ".nd-glance dt", text: "Website"
    # #200: the Website link carries the referral UTM so companies see the
    # visit in their own analytics. The href starts with the website, with
    # utm_source / utm_medium / utm_campaign on the query string.
    assert_select ".nd-glance dd a[href^='https://kairospower.com?']", text: "kairospower.com"
    link = css_select(".nd-glance dd a[href^='https://kairospower.com?']").first
    params = URI.decode_www_form(URI.parse(link["href"]).query).to_h
    assert_equal "nuclear-directory", params["utm_source"]
    assert_equal "referral", params["utm_medium"]
    assert_equal "company-page", params["utm_campaign"]
    assert_select ".nd-glance dd", text: "Alameda, CA"
    assert_select ".nd-glance dt + dd", minimum: 3 # headquarters, website, other names
    assert_select ".nd-glance dt", text: "Founded", count: 0
    assert_select ".nd-glance .nd-src, .nd-glance .nd-badge", 0
    assert_select ".nd-glance", text: /checked/, count: 0
  end

  test "a parent company shows in the key facts, not as a deal" do
    parent = company("Southern Company")
    cite!(link(@kairos, "subsidiary_of", parent))
    get company_path(slug: "kairos-power")

    assert_select ".nd-glance dt", "Parent company"
    assert_select ".nd-glance dd a[href='/companies/southern-company']", "Southern Company"
    assert_select ".nd-crow", text: /subsidiary/, count: 0
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

  test "the page's order: index, header, key facts, deals, plants, the quiet line" do
    get company_path(slug: "kairos-power")

    order = css_select(".nd-company > *").map { |el| el["class"][/nd-company__\w+/] }
    assert_equal %w[nd-company__index nd-company__head nd-company__glance nd-company__main nd-company__end], order
    assert_select ".nd-company__index nav.nd-idx[aria-label='On this page']" do
      assert_select "a", text: /Overview/
      assert_select "a[href='#deals']", /Deals and links\s*2/
      assert_select "a[href='#plants']", /Plants and sites\s*1/
      assert_select "a[href='#sources']", /Sources\s*2/
    end
  end

  test "facts without a source aren't shown" do
    bare = company("Bare Co", city: "Austin", state: "TX", roles: [ role("utility") ], website: "https://bare.example", description: "Runs plants.")
    link(bare, "supplies", @kairos)
    get company_path(slug: "bare-co")

    assert_response :success
    assert_select "body", text: /Runs plants|Austin|bare\.example|Kairos/, count: 0
    assert_select ".nd-tag", count: 0
    assert_select ".nd-gaps", 0, "no Not verified yet panel (removed 25 Oct)"
  end

  test "a company with only an invests-in deal gets the Investors breadcrumb" do
    backer = cite!(company("Backer Fund"))
    cite!(link(backer, "invests_in", @kairos))
    get company_path(slug: "backer-fund")

    assert_select ".nd-crumbs a[href=?]", "/companies?category=investors", text: "Investors"
  end

  test "the key facts have no Type chips: the tags and the trail say what the company is" do
    westinghouse = cite!(company("Westinghouse", roles: [ Role.find_by(key: "reactor_vendor") || role("reactor_vendor"), role("reactor_services") ]))
    cite!(link(westinghouse, "invests_in", @kairos))
    get company_path(slug: westinghouse.slug)

    assert_select ".nd-glance dt", text: "Type", count: 0
    assert_select ".nd-glance .nd-chip", 0
    assert_select ".nd-pagehead__tags .nd-tag", minimum: 2
    # Every tag carries an icon; a role takes its category's icon and colour.
    assert_select ".nd-pagehead__tags .nd-tag:not(.nd-tag--icon)", 0
    assert_select ".nd-pagehead__tags .nd-tag--icon.nd-bucket--reactor-developers svg", minimum: 1
    assert_select ".nd-pagehead__tags .nd-tag--icon.nd-bucket--services svg", minimum: 1
    assert_select ".nd-crumbs a[href=?]", "/companies?category=reactor-developers", text: "Developers"
  end

  test "the legal name isn't listed again under Also known as" do
    @kairos.update!(legal_name: "Kairos Power, LLC")
    get company_path(slug: "kairos-power")

    assert_select ".nd-glance dd", text: "Kairos Power, LLC", count: 1
  end

  test "a hidden invests-in deal doesn't make a company an investor" do
    backer = cite!(company("Quiet Fund"))
    link(backer, "invests_in", @kairos)
    get company_path(slug: "quiet-fund")

    assert_select ".nd-crumbs a", count: 0
  end

  test "a missing description or headquarters is left out, with no list of what's missing" do
    get company_path(slug: "google")

    assert_select ".nd-gaps", 0
    assert_select ".nd-pagehead__about", 0
    assert_select ".nd-glance dt", text: "Headquarters", count: 0
  end

  test "long lists collapse behind Show all" do
    (CompanyProfile::VISIBLE_ITEMS + 3).times do |i|
      cite!(link(company("Supplier #{i}"), "supplies", @kairos))
    end
    get company_path(slug: "kairos-power")

    suppliers = CompanyProfile::VISIBLE_ITEMS + 4 # and the DOE
    assert_select ".nd-partygroup", text: /Suppliers · #{suppliers}/ do
      assert_select "> ul.nd-crows > li", CompanyProfile::VISIBLE_ITEMS
      assert_select "details.nd-more summary .nd-more__open", "Show all #{suppliers} deals"
      assert_select "details.nd-more summary .nd-more__close", "Show fewer deals"
    end
  end

  test "one or two rows past the first six show, with no button" do
    (CompanyProfile::VISIBLE_ITEMS + 1).times do |i|
      cite!(link(company("Supplier #{i}"), "supplies", @kairos))
    end
    get company_path(slug: "kairos-power")

    assert_select ".nd-partygroup", text: /Suppliers/ do
      assert_select "> ul.nd-crows > li", CompanyProfile::VISIBLE_ITEMS + 2
      assert_select "details.nd-more", 0
    end
  end

  test "deals sit under labels that carry the verb; each row is the other company" do
    cite!(link(@kairos, "invests_in", company("Small Startup")))
    get company_path(slug: "kairos-power")

    assert_equal [ "Invests in", "Power buyers", "Suppliers" ], css_select(".nd-partygroup > h3.nd-label").map { |h| h.text.strip }
    assert_select ".nd-partygroup", text: /Power buyers/ do
      assert_select ".nd-crow__name", "Google"
      assert_select ".nd-crow__rest", 0, "no verb on the row"
      assert_select ".sr-only", /offtakes from Kairos Power/, "the full sentence is still read out"
    end
  end

  test "a company with no category, facts or links has no trail of one and no empty facts panel" do
    bare = company("Bare Co.")
    cite!(bare)
    get company_path(slug: bare.slug)

    assert_select ".nd-crumbs", 0
    assert_select ".nd-company__glance", 0
    assert_select "#cite .nd-cite", /“Bare Co\.” http/, "a name ending in a full stop isn't given a second one"
  end

  test "a plant the company owns and operates is one row" do
    both = cite!(plant("Both Roles Plant", facility_type: "power_reactor"))
    cite!(link(@kairos, "operates", both))
    cite!(link(@kairos, "owns", both))
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow--plant", text: /Both Roles Plant/, count: 1
    assert_select ".nd-crow--plant", text: /Both Roles Plant\s*operator and owner/
  end

  test "two units of one site stay two rows, each with its own role and sources" do
    site = plant("Split Site", facility_type: "power_reactor", status: "operating")
    unit3 = cite!(plant("Split Unit 3", parent: site, status: "operating"), source: @doe_page)
    unit4 = cite!(plant("Split Unit 4", parent: site, status: "operating"), source: @press)
    cite!(link(@kairos, "operates", unit3), source: @doe_page)
    cite!(link(@kairos, "owns", unit4), source: @press)
    get company_path(slug: "kairos-power")

    assert_select ".nd-crow--plant", text: /Split Site, Split Unit 3\s*operator/ do
      assert_select ".nd-crow__role", text: /operator\z/
      assert_select "a.nd-mark[data-sources]", 1
    end
    assert_select ".nd-crow--plant", text: /Split Site, Split Unit 4\s*owner/
    assert_select ".nd-crow--plant", text: /Split Unit 3.*owner/m, count: 0
    assert_select ".nd-crow--plant", text: /Split Unit 4.*operator/m, count: 0
  end

  test "key facts don't repeat the tags, and lists put one name per line" do
    get company_path(slug: "kairos-power")

    assert_select ".nd-tag", "Reactor designer"
    assert_select ".nd-glance dt", text: /\ARoles?\z/, count: 0
    assert_select ".nd-glance dt", text: "Technology", count: 0
    assert_select ".nd-glance .nd-glance__list > span", "Kairos"
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
