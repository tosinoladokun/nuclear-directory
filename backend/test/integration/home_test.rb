require "test_helper"
require_relative "../support/directory_builders"

class HomeTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    vendor = role("reactor_vendor")
    kairos = cite!(company("Kairos Power", roles: [ vendor ]))
    cite!(company("Oklo", roles: [ vendor ]))
    cite!(company("X-energy", roles: [ vendor ]))
    cite!(company("NuScale Power", roles: [ vendor ]))
    google = cite!(company("Google", roles: [ role("data_center_offtaker") ]))
    cite!(link(google, "offtake_with", kairos))
  end

  test "the real fonts always show: Roboto Mono and Roboto Serif swap in, with metric-matched fallbacks so nothing moves" do
    get root_path

    assert_match(/font-family: "Roboto Mono"[^}]*font-display: swap/, response.body)
    assert_match(/font-family: "Roboto Serif"[^}]*font-display: swap/, response.body)
    assert_includes response.body, "size-adjust"
  end

  test "no font is preloaded: the preload shared slow-4G bandwidth with the CSS and cost LCP 0.4 s" do
    get root_path
    assert_select "link[rel=preload][as=font]", count: 0
  end

  test "card titles are the category's own full name, in sentence case, on every width (Tosin, 2 Nov)" do
    shown = HomeCategories::Card.new(category: Category.find("waste-decommissioning"), count: 1, records: [])
    long = HomeCategories::Card.new(category: Category.find("utilities"), count: 1, records: [])
    html = ApplicationController.render(partial: "shared/category_cards", locals: { cards: [ shown, long ] })
    names = Nokogiri::HTML.fragment(html).css("a.nd-catcard__link .nd-catcard__name").map(&:text)
    assert_equal [ "Waste and decommissioning", "Power plant owners and operators" ], names
  end

  test "the home page has one job: search" do
    get root_path

    assert_response :success
    assert_select "title", "Nuclear Directory"
    assert_select "main", 1
    assert_select "h1", "Nuclear Directory"
    assert_select "header.nd-sitebar", count: 0
    assert_select "form[role=search][action='/companies'] input[name=q]"
    assert_select "label.sr-only", "Search a company, plant or site"
  end

  test "home names its canonical address" do
    get root_path

    assert_select "link[rel=canonical][href='http://www.example.com/']", 1
  end

  test "a card for each bucket with companies, then Plants and sites last, naming at most three (#362)" do
    get root_path

    # Reactor developers, Power buyers, Plants and sites: empty buckets have no card.
    assert_equal %w[reactor-developers power-buyers plants], css_select("section.nd-catcard").map { |card| card["data-key"] }
    assert_select "section.nd-catcard", 3
    assert_select "section[data-key=reactor-developers]" do
      assert_select "h2.nd-catcard__head a.nd-catcard__link[href=?][aria-label=?]", "/companies?category=reactor-developers", "Reactor developers, 4 companies"
      assert_select "a.nd-catcard__link .nd-catcard__count[aria-hidden=true]", "4"
      assert_select "a.nd-catcard__row", 3
      assert_select "a.nd-catcard__row[href=?][title=?]", "/companies/kairos-power", "Kairos Power", text: /Kairos Power/
      assert_select ".nd-catcard__more, .nd-catcard__chev", 0, "no See all link and no row chevrons: the title is the link"
    end
    assert_select "section[data-key=power-buyers]" do
      assert_select "a.nd-catcard__row", 1
      assert_select "li.nd-catcard__filler[aria-hidden=true]", 2
    end
    assert_select "section[aria-label='Plants and sites'] a.nd-catcard__link[aria-label=?]", "Plants and sites, 0 plants and sites"
    assert_select "details.nd-howpick", 0 # no explanation link (Tosin)
  end

  test "no company name repeats across the home cards" do
    vendor, fuel = %w[reactor_vendor fuel].map { |key| Role.find_by(key:) || role(key) }
    (1..4).map { |n| "Both Buckets Company #{n}" }.each { |name| cite!(company(name, roles: [ vendor, fuel ])) }
    get root_path

    names = css_select("section.nd-catcard:not([data-key=plants]) .nd-catcard__rowname").map { |row| row.text.strip }
    assert_not_empty names
    assert_equal names.uniq, names, "a company shows on one card only (Tosin, 18 Oct)"
  end

  test "the search field is wired to instant results" do
    get root_path

    assert_select ".nd-searchbox[data-controller=instant-search][data-instant-search-url-value='/search']"
    assert_select "input#search-large[role=combobox][aria-haspopup=dialog][aria-controls='search-large-results'][aria-expanded=false]"
    assert_select "#search-large-results[role=dialog][aria-label='Search results']"
    assert_select "#search-large-results[hidden] turbo-frame#search-large-frame"
    assert_select "#search-large-status[role=status][aria-live=polite]"
  end

  test "the site header on other pages uses the same instant search" do
    get companies_path

    assert_select "header.nd-sitebar .nd-searchbox[data-controller=instant-search] input#search-compact"
    assert_select "[data-instant-search-target=browse]", count: 0, message: "Browse is the home page's only"
  end

  test "the empty home search box has Browse: each category with companies, with its count, Plants and sites last (#909)" do
    cite!(plant("Plant Vogtle", facility_type: "power_reactor", status: "operating"))
    get root_path

    assert_select "#search-large-results .nd-browse[data-instant-search-target=browse][hidden]" do
      assert_select ".nd-label", "Browse"
      rows = css_select("a.nd-browse__row")
      assert_equal [ "Reactor developers", "Power buyers", "Plants and sites" ], rows.map { |row| row.at_css(".nd-browse__full").text }
      assert_equal %w[4 1 1], rows.map { |row| row.at_css(".nd-browse__count").text }
      assert_equal [ "/companies?category=reactor-developers", "/companies?category=power-buyers", "/companies?category=plants" ], rows.map { |row| row["href"] }, "the cards' own links"
      assert_equal "Reactor developers, 4 companies", rows.first["aria-label"]
      assert_equal "Plants and sites, 1 plant or site", rows.last["aria-label"]
    end
  end

  test "Browse shows the full category name, as the cards do; a long one carries its short name for narrow phones (#917)" do
    rows = [ HomeCategories::Browse.new(category: Category.find("utilities"), count: 36), HomeCategories::Browse.new(category: Category.find("fuel"), count: 3) ]
    html = ApplicationController.render(partial: "shared/search_box", locals: { size: :large, browse: rows })
    row, short = Nokogiri::HTML.fragment(html).css("a.nd-browse__row").to_a
    assert_equal "Power plant owners and operators", row.at_css(".nd-browse__full").text
    assert_equal "Plant operators", row.at_css("b[data-long] .nd-browse__short").text, "shown only under 360px"
    assert_equal "Power plant owners and operators", row.at_css("b")["title"]
    assert_equal "Fuel and materials", short.at_css("b").text
    assert_nil short.at_css("b[data-long]"), "a name that fits has no second name"
    assert_equal "Power plant owners and operators, 36 companies", row["aria-label"]
  end

  test "Browse rows keep 52px on touch phones: their rule outranks the 44px touch-target rule (#917 review)" do
    css = Rails.root.join("app/assets/tailwind/design_system/components.css").read
    assert_includes css, ".nd-searchbox__results .nd-browse__row { min-height: 52px; }"
    assert_includes css, ".nd-pill, .nd-select, .nd-instant__row, .nd-instant__all { min-height: 44px; }", "the rule it has to outrank (one class)"
  end

  test "the site icon sits beside the wordmark, decorative, and draws in only without reduced motion (#909)" do
    get root_path

    assert_select "h1.nd-home__wordmark > svg.nd-siteicon[aria-hidden=true] + svg.nd-wordmark__svg"
    assert_select "svg.nd-siteicon ellipse.nd-siteicon__orbit", 2
    assert_select "svg.nd-siteicon ellipse[pathLength]", 0, "some browsers ignore pathLength on an ellipse: the dash is in user units"
    css = Rails.root.join("app/assets/tailwind/design_system/components.css").read
    assert_match(/@media \(prefers-reduced-motion: no-preference\) \{\s*\.nd-siteicon__orbit \{[^}]*animation: nd-siteicon-draw 2\.25s ease-out both/, css,
      "the drawing runs only when motion is welcome; otherwise the orbits are simply there")
  end

  test "controllers are loaded on demand: no modulepreload of every controller on each page" do
    get root_path
    assert_select "link[rel=modulepreload][href*='/assets/controllers/']", 0
    assert_select "link[rel=modulepreload][href*='turbo']", minimum: 1
  end
end
