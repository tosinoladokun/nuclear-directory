require "application_system_test_case"
require_relative "../support/directory_builders"

# The empty home search box opens Browse (#909): the categories with their counts. Typing swaps in the results;
# clearing the box brings Browse back. The arrow keys move through Browse as through results.
class HomeBrowseTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    vendor = role("reactor_vendor")
    cite!(company("Kairos Power", roles: [ vendor ]))
    cite!(company("Oklo", roles: [ vendor ]))
    cite!(plant("Browns Ferry Nuclear Plant", facility_type: "power_reactor", status: "operating", city: "Athens", state: "AL"))
  end

  def field = find("#search-large")
  def status = find("#search-large-status", visible: :all).text(:all)

  test "focus opens Browse, typing shows results, clearing brings Browse back, Escape closes" do
    visit root_path
    field.click

    assert_selector ".nd-browse .nd-label", text: /\ABrowse\z/i
    assert_selector ".nd-browse__row", text: "Reactor developers"
    assert_selector ".nd-browse__row", text: "Plants and sites"
    assert_equal "true", field["aria-expanded"]
    assert_equal "Browse 2 categories, use the down arrow to browse", status

    field.send_keys(:down)
    assert_equal "Reactor developers", page.evaluate_script("document.activeElement.querySelector('b').textContent")
    page.driver.browser.action.send_keys(:arrow_up).perform
    assert_equal "search-large", page.evaluate_script("document.activeElement.id")

    field.send_keys("browns")
    assert_selector ".nd-instant__row", text: "Browns Ferry", wait: 20
    assert_no_selector ".nd-browse"

    field.send_keys([ :control, "a" ], :backspace)
    assert_selector ".nd-browse__row", text: "Reactor developers"

    field.send_keys(:escape)
    assert_no_selector "#search-large-results"
    assert_equal "false", field["aria-expanded"]
  end

  test "a late failure of a search that was cleared doesn't close Browse (#917 review)" do
    visit root_path
    field.click
    assert_selector ".nd-browse"
    # Index unavailable: typing goes to /search. Then clear the field before the request fails.
    page.execute_script("document.querySelector('[data-controller=instant-search]').dataset.instantSearchIndexUrlValue = ''")
    field.send_keys("kai")
    field.send_keys([ :control, "a" ], :backspace)
    assert_selector ".nd-browse__row", text: "Reactor developers"
    page.execute_script("document.querySelector('#search-large-results').dispatchEvent(new CustomEvent('turbo:fetch-request-error', { bubbles: true }))")

    assert_selector ".nd-browse__row", text: "Reactor developers"
    assert_equal "true", field["aria-expanded"]
  end

  test "one letter, below the two needed for results, closes Browse" do
    visit root_path
    field.click
    assert_selector ".nd-browse"

    field.send_keys("b")
    assert_no_selector "#search-large-results"
  end

  test "a Browse row goes to its list" do
    visit root_path
    field.click
    find(".nd-browse__row", text: "Reactor developers").click

    assert_current_path "/companies?category=reactor-developers"
  end
end
