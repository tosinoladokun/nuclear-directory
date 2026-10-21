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

    # Turbo and the controllers are loaded as modules; click once they are.
    assert page.evaluate_script("typeof Turbo !== 'undefined' && !!document.querySelector('turbo-frame#directory-rows[data-controller=keep-scroll]')")
    button = find("a", text: "Show more")
    page.execute_script("arguments[0].scrollIntoView({ block: 'center' })", button)
    covered = page.evaluate_script("(() => { const a = [...document.querySelectorAll('a')].find((el) => el.textContent.trim() === 'Show more'), r = a.getBoundingClientRect(); return document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2) !== a })()")
    assert_not covered, "nothing covers the Show more button"
    before = page.evaluate_script("Math.round(window.scrollY)")
    page.execute_script("window.__turbo = []; ['turbo:before-fetch-request', 'turbo:before-fetch-response', 'turbo:frame-render', 'turbo:frame-missing', 'turbo:fetch-request-error'].forEach((name) => document.addEventListener(name, (event) => window.__turbo.push(name + ':' + (event.detail?.fetchResponse?.statusCode || ''))))")
    button.click
    begin
      assert_selector "main ul.nd-list > li", count: DirectoryController::PAGE + 8, wait: 20
    rescue Minitest::Assertion
      flunk "Show more did not load the next page. Turbo saw: #{page.evaluate_script('JSON.stringify(window.__turbo)')}, frame src: #{page.evaluate_script("document.getElementById('directory-rows').getAttribute('src')")}, url: #{page.current_url}, rows: #{rows}"
    end
    assert_operator page.evaluate_script("Math.round(window.scrollY)"), :>=, before - 5, "the page didn't jump to the top"
    assert_no_selector "a", text: "Show more"
    assert_empty page.evaluate_script(AUDIT)
  end

  test "a company link in the list opens its page, not a frame" do
    visit companies_path
    first("main ul.nd-list > li a").click
    assert_selector "h1#profile-name", wait: 20
    assert_match(%r{\A/companies/paged-company}, page.current_path)
  end
end
