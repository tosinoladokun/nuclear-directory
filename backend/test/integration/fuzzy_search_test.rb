require "test_helper"
require_relative "../support/directory_builders"

# Search tolerates a missing letter, a plural or spacing (#431), but only when
# the exact search finds nothing, and it says so.
class FuzzySearchTest < ActionDispatch::IntegrationTest
  include DirectoryBuilders

  setup do
    @nextera = cite!(company("NextEra Energy"))
    @westinghouse = cite!(company("Westinghouse Reactor Systems"))
    @kairos = cite!(company("Kairos Power"))
    @browns = cite!(plant("Browns Ferry Nuclear Plant", facility_type: "power_reactor", status: "operating", city: "Athens", state: "AL"))
  end

  def names = css_select("main ul.nd-list a.nd-listrow .nd-listrow__name").map { |el| el.text.strip }

  test "'brown ferry' finds Browns Ferry, and the page says these are close names" do
    get companies_path(q: "brown ferry")

    assert_equal [ "Browns Ferry Nuclear Plant" ], names
    assert_select ".nd-fuzzy-note", "No exact match for “brown ferry”. Showing close names."
    assert_select "h1 .nd-listhead__count", /1 result/
  end

  test "'westinghous' finds Westinghouse and 'next era' finds NextEra" do
    get companies_path(q: "westinghous")
    assert_equal [ "Westinghouse Reactor Systems" ], names

    get companies_path(q: "next era")
    assert_equal [ "NextEra Energy" ], names
    assert_select ".nd-fuzzy-note"
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
    get search_path(q: "brown ferry")
    assert_select ".nd-instant__note", "No exact match for “brown ferry”. Showing close names."
    assert_select ".nd-instant__row", /Browns Ferry Nuclear Plant/

    get search_path(q: "Browns")
    assert_select ".nd-instant__note", 0
    assert_select ".nd-instant__row", /Browns Ferry Nuclear Plant/
  end

  test "unpublished names are never suggested" do
    company("Browne Ferrie Holdings", verified: false)
    get companies_path(q: "brown ferry")

    assert_equal [ "Browns Ferry Nuclear Plant" ], names
  end
end
