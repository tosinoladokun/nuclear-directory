require "application_system_test_case"
require_relative "../support/directory_builders"

# The instant search's live status tells a screen-reader user when the results are
# close names, since ArrowDown goes straight to the first result and skips the note.
class InstantSearchFuzzyTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup { cite!(plant("Browns Ferry Nuclear Plant", facility_type: "power_reactor", status: "operating", city: "Athens", state: "AL")) }

  def status = find("#search-large-status", visible: :all).text(:all)

  test "an exact search announces results; a typo announces close names" do
    visit root_path
    find("input[type=search]").send_keys("browns")
    assert_selector ".nd-instant__row", text: "Browns Ferry", wait: 20
    eventually { status.include?("1 result") }
    assert_not_includes status, "No exact match"

    find("input[type=search]").send_keys([ :control, "a" ], :backspace)
    find("input[type=search]").send_keys("browns fery")
    assert_selector ".nd-instant__note", wait: 20
    eventually { status == "No exact match. 1 close name, use the down arrow to browse" }
  end

  def eventually(wait: 15)
    page.document.synchronize(wait) { raise Capybara::ExpectationNotMet, "status was #{status.inspect}" unless yield }
  end
end
