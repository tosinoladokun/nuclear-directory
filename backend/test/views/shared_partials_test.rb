require "test_helper"

# Every shared partial with its fields present and with them missing:
# a missing field is left out, never guessed (DESIGN.md, "Data requirements").
class SharedPartialsTest < ActionView::TestCase
  helper DirectoryHelper
  helper IconHelper

  setup do
    @source = Source.new(url: "https://kairospower.com/news/a", domain: "kairospower.com",
      title: "Google and Kairos Power partner", published_on: Date.new(2024, 10, 14))
    @untitled = Source.new(url: "https://www.energy.gov/node/4845535", domain: "energy.gov")
  end

  test "company row with every field" do
    company = Organization.new(name: "Kairos Power", slug: "kairos-power", hq_city: "Alameda", hq_state: "CA",
      description: "Develops salt-cooled reactors.")
    render partial: "shared/company_row", locals: { organization: company, connections: 1 }

    assert_select "a.nd-listrow[href='/companies/kairos-power']"
    assert_select ".nd-mono", "KP"
    assert_select ".nd-listrow__desc", "Develops salt-cooled reactors."
    assert_select ".nd-listrow__side", /Alameda, CA/
    assert_select ".nd-listrow__side .nd-num", "1 connection"
  end

  test "company row leaves out what isn't known" do
    render partial: "shared/company_row", locals: { organization: Organization.new(name: "Oklo", slug: "oklo") }

    assert_select ".nd-listrow__name", "Oklo"
    assert_select ".nd-listrow__desc", count: 0
    assert_select ".nd-listrow__side", count: 0
  end

  test "power plant row with and without type, status and place" do
    render partial: "shared/plant_row", locals: { facility: facilities(:vogtle).tap { |f| f.verification_status = "verified" } }
    assert_select ".nd-listrow__desc", "Power plant · Operating"
    assert_select ".nd-listrow__side", /GA/

    render partial: "shared/plant_row", locals: { facility: Facility.new(name: "Hermes 2", slug: "hermes-2") }
    assert_select "a[href='/plants/hermes-2'] .nd-listrow__desc", count: 0
  end

  test "a pending site's row leaves out its own type, status and place" do
    render partial: "shared/plant_row", locals: { facility: facilities(:vogtle).tap { |f| f.verification_status = "pending" } }
    assert_select ".nd-listrow__desc", count: 0
    assert_select ".nd-listrow__side", count: 0
  end

  test "fact row shows the sentence, detail, quote, sources and confidence" do
    render partial: "shared/fact_row", locals: { sentence: "Google offtakes from Kairos Power", detail: "500 MW by 2035.",
      quote: "Kairos Power and Google have signed", citations: [ [ 1, @source ] ], confidence: 0.8 }

    assert_select ".nd-factrow__detail", "500 MW by 2035."
    assert_select ".nd-quote", "“Kairos Power and Google have signed”"
    assert_select "a.nd-src[href='#source-1']", /kairospower.com/
    assert_select ".nd-conf", /Medium/
  end

  test "fact row without detail, quote or confidence" do
    render partial: "shared/fact_row", locals: { sentence: "DOE funds Kairos Power", citations: [ [ 2, @untitled ] ] }

    assert_select ".nd-factrow__detail", count: 0
    assert_select ".nd-quote", count: 0
    assert_select ".nd-conf", count: 0
  end

  test "sources list uses the title, or the URL when there is none" do
    render partial: "shared/sources_list", locals: { sources: [ [ 1, @source ], [ 2, @untitled ] ] }

    assert_select "li#source-1 a", "Google and Kairos Power partner"
    assert_select "li#source-1 small", "kairospower.com · published 2024-10-14"
    assert_select "li#source-2 a", "https://www.energy.gov/node/4845535"
    assert_select "li#source-2 small", "energy.gov"
  end

  test "sources list never links a URL that isn't http(s)" do
    unsafe = Source.new(url: "javascript:alert(1)", title: "Looks harmless")
    render partial: "shared/sources_list", locals: { sources: [ [ 1, unsafe ] ] }

    assert_select "li#source-1 a", count: 0
    assert_select "li#source-1 span", text: "Looks harmless"
    assert_select "li#source-1 small", "unlinked source"
  end

  test "a source chip for a hostless URL still has a readable label" do
    render partial: "shared/source_chip", locals: { number: 3, source: Source.new(url: "javascript:alert(1)") }

    assert_select "a.nd-src[aria-label=?]", "Source 3: unlinked source"
  end

  test "sources list never shows a blank domain" do
    hostless = Source.new(url: "mailto:press@example.com", published_on: Date.new(2024, 10, 14))
    render partial: "shared/sources_list", locals: { sources: [ [ 1, hostless ] ] }

    assert_select "li#source-1 small", "unlinked source · published 2024-10-14"
  end

  test "fact row shows the checked date on its first source chip only" do
    render partial: "shared/fact_row", locals: { sentence: "Google offtakes from Kairos Power",
      citations: [ [ 1, @source ], [ 2, @untitled ] ], checked: Date.new(2026, 10, 9) }

    assert_select "a.nd-src[href='#source-1']", /checked 2026-10-09/
    assert_select "a.nd-src[href='#source-1'][aria-label=?]", "Source 1: kairospower.com, checked 2026-10-09"
    assert_select "a.nd-src[href='#source-2']", text: /checked/, count: 0
    assert_select "a.nd-src[href='#source-2'][aria-label=?]", "Source 2: energy.gov"
  end

  test "overview panel skips rows without a value" do
    render partial: "shared/overview_panel", locals: { verified_at: Time.zone.parse("2026-10-09"),
      rows: [ [ "Website", "kairospower.com", nil ], [ "HQ", nil, nil ], [ "Role", "Reactor developer", [ [ 1, @source ] ] ] ] }

    assert_select "dt", count: 2
    assert_select "dt", text: "HQ", count: 0
    assert_select "dd a.nd-src sup", "1"
    assert_select ".nd-badge--verified", /Verified/
    assert_select ".nd-overview__foot", /checked 2026-10-09/
  end

  test "profile header with and without description and tags" do
    render partial: "shared/profile_header", locals: { name: "Kairos Power", kind: :company,
      description: "Develops salt-cooled reactors.", citations: [ [ 1, @source ] ], tags: [ "Reactor developer" ] }
    assert_select "h1", "Kairos Power"
    assert_select ".nd-profile__desc", /Develops salt-cooled reactors./
    assert_select ".nd-tag", "Reactor developer"

    render partial: "shared/profile_header", locals: { name: "Hermes 2", kind: :plant, heading_id: "plant-name" }
    assert_select ".nd-ring--lg"
    assert_select "section[aria-labelledby=plant-name] h1#plant-name", "Hermes 2"
  end

  test "missing fields box lists gaps, and disappears when there are none" do
    render partial: "shared/missing_fields", locals: { fields: [ "Location", "Status" ], suggest_url: "/suggest" }
    assert_select ".nd-gaps li", count: 2
    assert_select ".nd-gaps a[href='/suggest']", "Suggest a source"

    assert_empty render(partial: "shared/missing_fields", locals: { fields: [] }).strip
  end

  test "confidence renders nothing when unknown" do
    assert_empty render(partial: "shared/confidence", locals: { value: nil }).strip
  end

  test "category pills mark the current one and show counts when given" do
    render partial: "shared/category_pills", locals: { current: Category.find("fuel"), counts: { "fuel" => 11 } }

    assert_select "a.nd-pill", count: 10
    assert_select "a.nd-pill.nd-bucket--fuel[aria-current='page']", /Fuel and materials/
    assert_select "a.nd-pill.nd-bucket--fuel svg.nd-ic", 1
    assert_select "nav.nd-pills[data-controller=pill-row]", 1, "scrolls the current pill into view on phones"
    assert_select "a.nd-pill[href=?]:not([class*=nd-bucket--]) svg.nd-ic", "/companies?category=plants", 1, "Plants and sites has no accent"
    assert_select "a.nd-pill[aria-current='page'] .nd-num", "11"
    assert_select "a.nd-pill[href=?]", "/companies?category=plants", text: /Plants and sites/
  end

  test "empty buckets are hidden from the pills, unless it's the one shown" do
    render partial: "shared/category_pills", locals: { current: Category.find("components"), counts: { "fuel" => 2, "components" => 0, "investors" => 0 } }

    assert_select "a.nd-pill", count: 9
    assert_select "a.nd-pill[href=?]", "/companies?category=investors", count: 0
    assert_select "a.nd-pill[aria-current='page']", /Components and manufacturing/
  end

  test "category boxes show examples when there are any, and hide empty buckets" do
    render partial: "shared/category_boxes", locals: { examples: { "fuel" => [ "Centrus Energy", "Urenco USA" ] } }

    assert_select "a.nd-cat", count: 10
    assert_select "a.nd-cat[href=?] span", "/companies?category=fuel", text: "Centrus Energy, Urenco USA"
    assert_select "a.nd-cat.nd-bucket--fuel b svg.nd-ic.nd-ic--24", 1, "the bucket's icon beside its name, at 24px"
    assert_select "a.nd-cat[href=?] span", "/companies?category=fusion", count: 0

    render partial: "shared/category_boxes", locals: { examples: {}, counts: { "fuel" => 3, "components" => 0 } }
    assert_select "a.nd-cat[href=?]", "/companies?category=components", count: 0
  end

  test "empty state with and without an action" do
    render partial: "shared/empty_state", locals: { message: "No results.", action_label: "Clear search", action_url: "/companies" }
    assert_select ".nd-notice a[href='/companies']", "Clear search"

    render partial: "shared/empty_state", locals: { message: "No results." }
    assert_select ".nd-notice", /No results./
  end
end
