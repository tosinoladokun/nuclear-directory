require "test_helper"
require_relative "../support/directory_builders"

# Typo tolerance (#431): a missing or wrong letter finds the name, but only when
# the exact search (which already ignores spacing and matches every word, #495)
# finds nothing, and the page says so.
class FuzzySearchTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    @nextera = cite!(company("NextEra Energy"))
    @westinghouse = cite!(company("Westinghouse Reactor Systems"))
    @kairos = cite!(company("Kairos Power"))
    @browns = cite!(plant("Browns Ferry Nuclear Plant", facility_type: "power_reactor", status: "operating", city: "Athens", state: "AL"))
  end

  def names = css_select("main ul.nd-list a.nd-listrow .nd-listrow__name").map { |el| el.text.strip }

  test "a missing letter finds the name, and the page says these are close names" do
    get companies_path(q: "browns fery")

    assert_equal [ "Browns Ferry Nuclear Plant" ], names
    assert_select ".nd-fuzzy-note", "No exact match for “browns fery”. Showing close names."
    assert_select "h1 .nd-listhead__count", /1 result/
  end

  test "typos in a company name: 'westinghus', 'nextara energy'" do
    get companies_path(q: "westinghus")
    assert_equal [ "Westinghouse Reactor Systems" ], names
    assert_select ".nd-fuzzy-note"

    get companies_path(q: "nextara energy")
    assert_equal [ "NextEra Energy" ], names
    assert_select ".nd-fuzzy-note"
  end

  test "spacing, every-word and cut-off matches stay exact: no note ('next era', 'brown ferry', 'westinghous')" do
    get companies_path(q: "westinghous")
    assert_equal [ "Westinghouse Reactor Systems" ], names
    assert_select ".nd-fuzzy-note", 0

    get companies_path(q: "brown ferry")
    assert_equal [ "Browns Ferry Nuclear Plant" ], names
    assert_select ".nd-fuzzy-note", 0

    get companies_path(q: "next era")
    assert_equal [ "NextEra Energy" ], names
    assert_select ".nd-fuzzy-note", 0
  end

  test "an exact match shows no close names and no note" do
    get companies_path(q: "Kairos")

    assert_equal [ "Kairos Power" ], names
    assert_select ".nd-fuzzy-note", 0
  end

  test "a search nothing is close to keeps the empty state and shows no note" do
    get companies_path(q: "zzzzqqqq")

    assert_select ".nd-notice", /No results for “zzzzqqqq”/
    assert_select ".nd-fuzzy-note", 0
  end

  test "a very short query is not matched loosely" do
    get companies_path(q: "ne")
    assert_select ".nd-fuzzy-note", 0
  end

  test "the instant results do the same, with the note, and only on a fallback" do
    get search_path(q: "browns fery")
    assert_select ".nd-instant__note", "No exact match for “browns fery”. Showing close names."
    assert_select ".nd-instant__row", /Browns Ferry Nuclear Plant/

    get search_path(q: "Browns")
    assert_select ".nd-instant__note", 0
    assert_select ".nd-instant__row", /Browns Ferry Nuclear Plant/
  end

  test "the filter sheet's JSON count matches the close names the page shows" do
    get companies_path(q: "browns fery", format: :json)

    assert_equal 1, JSON.parse(response.body)["count"]
  end

  test "close names are ranked among the records the filters leave, not before them" do
    10.times { |n| cite!(company("Browns Ferry Group #{('a'.ord + n).chr}", state: "TX")) }
    cite!(company("Browns Ferry Services Company of Alabama", state: "AL"))

    get companies_path(q: "browns fery", state: "AL")
    assert_includes names, "Browns Ferry Services Company of Alabama"
    assert_empty names.grep(/Group/), "none of the Texas companies"
    assert_select ".nd-fuzzy-note"
  end

  test "unpublished names are never suggested" do
    company("Browns Fery Holdings", verified: false)
    get companies_path(q: "browns fery")

    assert_equal [ "Browns Ferry Nuclear Plant" ], names
  end
end
