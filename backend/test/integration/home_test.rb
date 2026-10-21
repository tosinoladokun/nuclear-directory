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

  test "Roboto Mono never swaps in late: a late swap shifted the /companies list (Lighthouse 0.85)" do
    get root_path
    assert_match(/font-family: "Roboto Mono".*?font-display: optional/, response.body)
  end

  test "no font is preloaded: the preload shared slow-4G bandwidth with the CSS and cost LCP 0.4 s" do
    get root_path
    assert_select "link[rel=preload][as=font]", count: 0
    assert_match(/font-family: "Roboto Serif".*?font-display: optional/, response.body, "a swapped-in serif moved the page (CLS 0.25 in CI)")
  end

  test "card titles are the home page's proper-noun labels; the category's name stays in title" do
    shown = HomeCategories::Card.new(category: Category.find("waste-decommissioning"), count: 1, records: [])
    long = HomeCategories::Card.new(category: Category.find("utilities"), count: 1, records: [])
    html = ApplicationController.render(partial: "shared/category_cards", locals: { cards: [ shown, long ] })
    names = Nokogiri::HTML.fragment(html).css("a.nd-catcard__head .nd-catcard__name").map(&:text)
    assert_equal [ "Waste and Decommissioning", "Plant Operators" ], names
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

  test "five suggested searches from the pool, picked on the server, each leading to results" do
    get root_path

    labels = css_select(".nd-suggs a.nd-sugg:not(.nd-sugg--spare)").map { |link| link.text.strip }
    assert_equal HomeSuggestions::SHOWN, labels.size
    assert_empty labels - HomeSuggestions::POOL.map(&:label)
    assert_equal labels, labels.sort_by { |label| HomeSuggestions::POOL.index { |s| s.label == label } }, "in pool order"
    css_select(".nd-suggs a.nd-sugg").each { |link| assert_match(%r{\A/companies\?from=suggestion&q=}, link["href"]) }

    spares = css_select(".nd-suggs a.nd-sugg--spare")
    assert_equal HomeSuggestions::POOL.size - HomeSuggestions::SHOWN, spares.size, "the rest of the pool is on the page, hidden"
    assert(spares.all? { |link| link["hidden"] }, "spares are hidden until the row needs them")
    assert_equal spares.map { |link| link.text.strip.length }, spares.map { |link| link.text.strip.length }.sort, "shortest first"
  end

  test "a seeded pick is the same every load; different seeds show different pills" do
    HomeController.suggestion_random = Random.new(1)
    get root_path
    first = css_select(".nd-suggs a.nd-sugg").map(&:text)
    HomeController.suggestion_random = Random.new(1)
    get root_path
    assert_equal first, css_select(".nd-suggs a.nd-sugg").map(&:text)

    picks = (1..30).map { |seed| HomeSuggestions.pick(random: Random.new(seed)).map(&:label) }
    assert_operator picks.uniq.size, :>, 1, "the pills vary from load to load"
  ensure
    HomeController.suggestion_random = nil
  end

  test "the top searches are picked far more often than the rest" do
    random = Random.new(42)
    tally = 2000.times.flat_map { HomeSuggestions.pick(random:).map(&:label) }.tally
    top, rest = HomeSuggestions::POOL.partition { |s| s.weight > 1 }.map { |group| group.sum { |s| tally.fetch(s.label, 0) } / group.size.to_f }
    assert_operator top, :>, rest * 2
  end

  test "a card for each bucket with companies, then Plants and sites last, naming at most three (#362)" do
    get root_path

    # Developers, Power buyers, Plants and sites: empty buckets have no card.
    assert_equal %w[reactor-developers power-buyers plants], css_select("section.nd-catcard").map { |card| card["data-key"] }
    assert_select "section.nd-catcard", 3
    assert_select "section[data-key=reactor-developers]" do
      assert_select "a.nd-catcard__head[href=?][aria-label=?]", "/companies?category=reactor-developers", "Reactor Developers, 4 companies"
      assert_select "section[data-label=?]", "Reactor Developers, 4 companies"
      assert_select "h2.nd-catcard__head--toggle", /Developers/, "the phone header, which shows no count"
      assert_select "a.nd-catcard__row", 3
      assert_select "a.nd-catcard__row[href=?][title=?]", "/companies/kairos-power", "Kairos Power", text: /Kairos Power/
      assert_select "a.nd-catcard__more[href=?][aria-label=?]", "/companies?category=reactor-developers", "See all 4 in Developers", text: /\A\s*See all ›\s*\z/
      assert_select "a.nd-catcard__head .nd-catcard__count[aria-hidden=true]", "4"
    end
    assert_select "section[data-key=power-buyers]" do
      assert_select "a.nd-catcard__row", 1
      assert_select "li.nd-catcard__filler[aria-hidden=true]", 2
      assert_select "a.nd-catcard__more[aria-label=?]", "Open the list of 1 company in Power buyers", text: /Open the list ›/
    end
    assert_select "section[aria-label='Plants and sites'] a.nd-catcard__head[aria-label=?]", "Plants and Sites, 0 plants and sites"
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
  end
end
