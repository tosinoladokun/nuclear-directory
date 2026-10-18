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

  test "four suggested searches that lead to results" do
    get root_path

    assert_select ".nd-suggs a.nd-sugg", 4
    assert_select ".nd-suggs a[href=?]", "/companies?q=HALEU", text: "HALEU"
    assert_select ".nd-suggs a[href=?]", "/companies?category=power-buyers", text: "Power deals"
  end

  test "category boxes show the most connected verified names" do
    get root_path

    # Developers, Plants and sites, Power buyers: empty buckets are hidden.
    assert_select "a.nd-cat", 3
    assert_select "a.nd-cat[href=?] span", "/companies?category=reactor-developers", text: "Kairos Power, NuScale Power, Oklo"
    assert_select "a.nd-cat[href=?] span", "/companies?category=fusion", count: 0
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
