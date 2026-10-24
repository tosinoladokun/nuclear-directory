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

  # The rows appear when Turbo renders the frame; scroll and focus are put back in the
  # frame-render event just after. Wait for them rather than reading at once, which
  # could land between the two.
  def eventually(message, wait: 15)
    page.document.synchronize(wait) do
      ok = begin
        yield
      rescue Selenium::WebDriver::Error::StaleElementReferenceError
        false # the frame was replaced under us; look again
      end
      raise Capybara::ExpectationNotMet, message unless ok
    end
  end

  def rows = page.evaluate_script("document.querySelectorAll('main ul.nd-list > li').length")

  # Activates Show more once and waits for the rows. The page is several counts
  # and a list, which can take seconds when the machine is busy (in CI and locally
  # the request was answered late, never lost), so repeating the click only queues
  # more work: wait longer instead.
  def show_more(expected_rows, via: :click, selector: "main ul.nd-list > li")
    if via == :keyboard
      page.execute_script("[...document.querySelectorAll('a')].find((el) => el.textContent.trim() === 'Show more').focus()")
      page.send_keys(:enter)
    else
      find("a", text: "Show more").click
    end
    assert_selector selector, count: expected_rows, wait: 45
  end

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
    show_more(DirectoryController::PAGE + 8)
    eventually("the page jumped to the top (was #{before})") { page.evaluate_script("Math.round(window.scrollY)") >= before - 5 }
    assert_no_selector "a", text: "Show more"
    assert_empty page.evaluate_script(AUDIT)
  end

  test "a keyboard user who activates Show more keeps their place: focus lands on the first new result and Tab goes on from there" do
    visit companies_path
    assert page.evaluate_script("typeof Turbo !== 'undefined' && !!document.querySelector('turbo-frame#directory-rows[data-controller=keep-scroll]')")
    show_more(DirectoryController::PAGE + 8, via: :keyboard)

    eventually("the first newly shown company should have focus") do
      page.evaluate_script("(() => { const rows = [...document.querySelectorAll('ul.nd-list a.nd-listrow')]; return [rows.indexOf(document.activeElement), rows.length] })()") == [ DirectoryController::PAGE, DirectoryController::PAGE + 8 ]
    end
    page.send_keys(:tab)
    assert_equal DirectoryController::PAGE + 1, page.evaluate_script("[...document.querySelectorAll('ul.nd-list a.nd-listrow')].indexOf(document.activeElement)"), "Tab moves to the next company"
  end

  test "with companies and plants both expanding, keyboard focus lands on a new result that is on screen" do
    Facility.insert_all((DirectoryController::PAGE + 6).times.map { |i| { name: "Paged Station #{i}", slug: "paged-station-#{i}", facility_type: "power_reactor", status: "operating",
      verification_status: "verified", verified_by: "human:tosin", created_at: Time.current, updated_at: Time.current } })
    visit companies_path(q: "Paged")
    assert page.evaluate_script("typeof Turbo !== 'undefined' && !!document.querySelector('turbo-frame#directory-rows[data-controller=keep-scroll]')")
    before = page.evaluate_script("document.querySelectorAll('ul.nd-list a.nd-listrow').length")
    page.execute_script("[...document.querySelectorAll('a')].find((el) => el.textContent.trim() === 'Show more').scrollIntoView({ block: 'end' })")
    show_more(before + 14, via: :keyboard, selector: "ul.nd-list > li")

    eventually("focus should be on a newly shown row that is inside the viewport") do
      page.evaluate_script("(() => { const rows = [...document.querySelectorAll('ul.nd-list a.nd-listrow')], i = rows.indexOf(document.activeElement), r = document.activeElement.getBoundingClientRect(); const page = #{DirectoryController::PAGE}; return [(i >= page && i < page + 8) || i >= page + 8 + page, r.top >= 0 && r.bottom <= innerHeight] })()") == [ true, true ]
    end
  end

  test "a company link in the list opens its page, not a frame" do
    visit companies_path
    first("main ul.nd-list > li a").click
    assert_selector "h1#profile-name", wait: 20
    assert_match(%r{\A/companies/paged-company}, page.current_path)
  end
end
