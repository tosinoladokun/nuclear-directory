require "test_helper"
require_relative "../support/directory_builders"

class SearchTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    vendor = role("reactor_vendor")
    company("Kairos Power", city: "Alameda", state: "CA", roles: [ vendor ])
    company("Kairos Ghost", roles: [ vendor ], verified: false)
    plant("Kairos Hermes", facility_type: "research_reactor", city: "Oak Ridge", state: "TN")
  end

  test "instant results come back grouped in a Turbo Frame, without the layout" do
    get search_path(q: "kairos")

    assert_response :success
    assert_not_includes response.body, "<html"
    assert_select "turbo-frame#instant-results[target=_top]"
    assert_select "#instant-results-companies", "Companies"
    assert_select ".nd-instant__row[href='/companies/kairos-power']", /Kairos Power.*Reactor designer · Alameda, CA/m
    assert_select "#instant-results-plants", "Plants and sites"
    assert_select ".nd-instant__row[href='/plants/kairos-hermes']", /Test reactor · Oak Ridge, TN/
    assert_select ".nd-instant[data-instant-search-count='2']"
    assert_select ".nd-instant__all[href=?]", "/companies?q=kairos", text: /All results for “kairos”/
  end

  test "a company's result has its category square, not letter boxes" do
    cite!(Organization.find_by!(slug: "kairos-power"))
    get search_path(q: "kairos")

    assert_select ".nd-instant__row[href='/companies/kairos-power'] .nd-catsq.nd-bucket--reactor-developers svg"
    assert_select ".nd-instant .nd-mono", 0, "no initials boxes"
  end

  test "an unpublished role doesn't show on a published company's result" do
    OrganizationRole.joins(:organization).find_by!(organizations: { name: "Kairos Power" }).unpublish!(by: "human:test")

    get search_path(q: "kairos power")

    assert_select ".nd-instant__row[href='/companies/kairos-power']"
    assert_select ".nd-instant__row[href='/companies/kairos-power']", text: /Reactor designer/, count: 0
  end

  test "only verified records appear" do
    get search_path(q: "ghost")

    assert_select ".nd-instant__row", count: 0
    assert_select ".nd-instant__empty", "No results for “ghost”. Check the spelling, or search a company or plant name."
  end

  test "the response fills the frame Turbo asked for" do
    get search_path(q: "kairos"), headers: { "Turbo-Frame" => "search-compact-frame" }
    assert_select "turbo-frame#search-compact-frame"

    get search_path(q: "kairos"), headers: { "Turbo-Frame" => "<bad id>" }
    assert_select "turbo-frame#instant-results"
  end

  test "a query shorter than two characters returns an empty frame" do
    get search_path(q: "k")

    assert_select "turbo-frame#instant-results"
    assert_select ".nd-instant", count: 0
  end

  test "results are capped so the list stays short" do
    vendor = Role.find_by!(key: "reactor_vendor")
    8.times { |i| company("Kairos Clone #{i}", roles: [ vendor ]) }
    get search_path(q: "kairos")

    assert_select "ul[aria-labelledby=instant-results-companies] li", SearchController::COMPANY_LIMIT
  end
end
