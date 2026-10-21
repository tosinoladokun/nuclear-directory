require "application_system_test_case"
require_relative "../support/directory_builders"

# /companies pages its rows: Show more swaps the next page in place, keeps the
# scroll position and obeys the one-line rule at 390.
class DirectoryShowMoreTest < ApplicationSystemTestCase
  include DirectoryBuilders

  AUDIT = File.readlines(File.expand_path("../support/no_wrap_audit.js", __dir__)).reject { |line| line.start_with?("//") }.join

  setup do
    fuel = role("fuel")
    (DirectoryController::PAGE + 8).times do |n|
      cite!(company("Paged Company Number #{n} Holdings International Incorporated", roles: [ fuel ], city: "Springfield", state: "IL",
        description: "Company that supplies uranium conversion and enrichment services to nuclear power plants, number #{n}."))
    end
  end

  def rows = page.evaluate_script("document.querySelectorAll('main ul.nd-list > li').length")

  test "Show more adds the next page in place, keeps the scroll position" do
    resize_viewport(390, 844)
    visit companies_path
    assert_equal DirectoryController::PAGE, rows
    assert_empty page.evaluate_script(AUDIT)

    page.execute_script("window.scrollTo(0, document.body.scrollHeight)")
    before = page.evaluate_script("Math.round(window.scrollY)")
    click_on "Show more"
    assert_selector "main ul.nd-list > li", count: DirectoryController::PAGE + 8, wait: 15
    assert_operator page.evaluate_script("Math.round(window.scrollY)"), :>=, before - 5, "the page didn't jump to the top"
    assert_no_selector "a", text: "Show more"
    assert_empty page.evaluate_script(AUDIT)
  end
end
