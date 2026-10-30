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
      rows: [ [ "Website", "kairospower.com", nil ], [ "HQ", nil, nil ], [ "Role", "Reactor designer", [ [ 1, @source ] ] ] ] }

    assert_select "dt", count: 2
    assert_select "dt", text: "HQ", count: 0
    assert_select "dd a.nd-src sup", "1"
    assert_select ".nd-badge--verified", /Verified/
    assert_select ".nd-overview__foot", /checked 2026-10-09/
  end

  test "profile header with and without description and tags" do
    render partial: "shared/profile_header", locals: { name: "Kairos Power", kind: :company,
      description: "Develops salt-cooled reactors.", citations: [ [ 1, @source ] ], tags: [ "Reactor designer" ] }
    assert_select "h1", "Kairos Power"
    assert_select ".nd-profile__desc", /Develops salt-cooled reactors./
    assert_select ".nd-tag", "Reactor designer"

    render partial: "shared/profile_header", locals: { name: "Hermes 2", kind: :plant, heading_id: "plant-name" }
    assert_select ".nd-ring--lg"
    assert_select "section[aria-labelledby=plant-name] h1#plant-name", "Hermes 2"
  end

  test "every partial that links into /corrections says nofollow, so a page needn't be crawled for them (#653)" do
    render partial: "shared/missing_fields", locals: { fields: [ "Location" ], suggest_url: "/corrections/new?subject=x" }
    assert_select ".nd-gaps a[href^='/corrections'][rel~=nofollow]", "Suggest a source"

    render partial: "shared/overview_panel", locals: { verified_at: Time.zone.parse("2026-10-09"), rows: [], correction_url: "/corrections/new?subject=x" }
    assert_select "a.nd-overview__fix[rel~=nofollow]", "Report a correction"

    render partial: "shared/fact_row", locals: { sentence: "Google offtakes from Kairos Power", citations: [], correctable: true }
    assert_select "a.nd-factrow__fix[href^='/corrections'][rel~=nofollow]"

    render partial: "shared/page_end", locals: { sources: [], cite_text: "x", subject: "Kairos Power" }
    assert_select "nav.nd-quiet a[href^='/corrections'][rel~=nofollow]"
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

  test "category cards: icon in the bucket's colour, names linking to their pages, fillers only when short" do
    centrus = Organization.new(name: "Centrus Energy", slug: "centrus-energy")
    vogtle = Facility.new(name: "Plant Vogtle", slug: "plant-vogtle")
    render partial: "shared/category_cards", locals: { cards: [
      HomeCategories::Card.new(category: Category.find("fuel"), count: 1, records: [ centrus ]),
      HomeCategories::Card.new(category: Category.find("plants"), count: 5, records: [ vogtle ])
    ] }

    assert_select "section.nd-catcard.nd-bucket--fuel .nd-catcard__head--link svg.nd-ic.nd-ic--24", 1
    assert_select "section.nd-catcard.nd-bucket--fuel a.nd-catcard__row[href=?]", "/companies/centrus-energy", text: /Centrus Energy/
    assert_select "section.nd-catcard.nd-bucket--fuel li.nd-catcard__filler", 2
    assert_select "section.nd-catcard:not([class*=nd-bucket--]) a.nd-catcard__row[href=?]", "/plants/plant-vogtle"
    assert_select "section.nd-catcard:not([class*=nd-bucket--]) a.nd-catcard__more[aria-label=?]", "See all 5 in Plants and sites", text: /See all ›/
    assert_select "section.nd-catcard.nd-bucket--fuel a.nd-catcard__more[aria-label=?]", "Open the list of 1 company in Fuel and materials", text: /Open the list ›/

    render partial: "shared/category_cards", locals: { cards: [ HomeCategories::Card.new(category: Category.find("utilities"), count: 14, records: [ centrus ]) ] }
    assert_select "a.nd-catcard__head[aria-label=?]", "Plant operators (#{Category.find("utilities").name}), 14 companies"
  end

  test "empty state with and without an action" do
    render partial: "shared/empty_state", locals: { message: "No results.", action_label: "Clear search", action_url: "/companies" }
    assert_select ".nd-notice a[href='/companies']", "Clear search"

    render partial: "shared/empty_state", locals: { message: "No results." }
    assert_select ".nd-notice", /No results./
  end
end
