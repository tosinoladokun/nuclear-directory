require "application_system_test_case"
require_relative "../support/directory_builders"

# The list pages (#560): the category index stays in view while the list scrolls, the redesigned rows and
# chips are covered by the shared no-wrap audit (and the audit still catches them when they break).
class ListPageSystemTest < ApplicationSystemTestCase
  include DirectoryBuilders

  AUDIT = File.readlines(File.expand_path("../support/no_wrap_audit.js", __dir__)).reject { |line| line.start_with?("//") }.join

  setup do
    fuel = role("fuel")
    30.times { |n| cite!(company("Listed Company Number #{n} Holdings International Incorporated", roles: [ fuel ], city: "Springfield", state: "IL")) }
  end

  test "the category index sticks while the list scrolls" do
    resize_viewport(1440, 700)
    visit companies_path
    page.execute_script("window.scrollTo(0, 600)")
    top = page.evaluate_script("document.querySelector('.nd-idx--list').getBoundingClientRect().top")

    assert_operator top, :<=, 60, "the index follows the scroll"
    assert_operator top, :>=, 0
  end

  [ [ 390, 844 ], [ 1440, 900 ] ].each do |width, height|
    test "the list page's rows, chips and index labels are audited at #{width}" do
      resize_viewport(width, height)
      visit companies_path
      assert_selector ".nd-line__name", minimum: 5
      assert_empty page.evaluate_script(AUDIT)
    end
  end

  test "the audit catches a wrapping name and a cut-short location with no full text in title" do
    resize_viewport(1440, 900)
    visit companies_path
    page.execute_script(<<~JS)
      const box = document.createElement("div")
      box.innerHTML = '<span class="nd-line__name" style="display:inline-block;width:40px;white-space:normal">A deliberately long company name</span>' +
        '<span class="nd-line__end" style="display:inline-block;width:30px;overflow:hidden;white-space:nowrap">A long place, far away</span>'
      document.querySelector("main").prepend(box)
    JS
    problems = page.evaluate_script(AUDIT)

    assert problems.any? { |problem| problem.start_with?("wraps: nd-line__name") }, problems.inspect
    assert problems.any? { |problem| problem.start_with?("cut short with no full text in title: nd-line__end") }, problems.inspect
  end
end
