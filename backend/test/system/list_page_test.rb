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

  test "inline filters apply as they change, with no Apply button; the phone sheet keeps its button (#700)" do
    cite!(company("Texas Co", roles: [ role("reactor_vendor") ], state: "TX", city: "Austin"))
    resize_viewport(1440, 900)
    visit companies_path
    assert_selector ".nd-filters[data-live]"
    assert_not page.evaluate_script("[...document.querySelectorAll('.nd-filters [type=submit]')].some((b) => b.getClientRects().length)"), "no Apply button inline"
    find("select[name=state]", match: :first).find("option", text: "TX").select_option
    assert_current_path(/state=TX/, wait: 10)
    assert_selector "select[name=state]:focus", wait: 5

    resize_viewport(390, 844)
    visit companies_path
    assert_selector ".nd-filters[data-live]", visible: :all
    find(".nd-filterwrap__open").click
    assert_selector ".nd-filtersheet [type=submit]", visible: true
  end

  test "a choice made in the phone sheet and never applied is dropped when the sheet closes (rotating to desktop)" do
    cite!(company("Texas Co", roles: [ role("reactor_vendor") ], state: "TX", city: "Austin"))
    resize_viewport(390, 844)
    visit companies_path
    assert_selector ".nd-filters[data-live]", visible: :all
    find(".nd-filterwrap__open").click
    find(".nd-filtersheet select[name=state]").find("option", text: "TX").select_option
    resize_viewport(1440, 900)
    assert_no_selector "dialog[open]", wait: 5
    assert_equal "", find("select[name=state]", match: :first).value
  end

  [ [ 390, 844 ], [ 1144, 900 ], [ 1279, 900 ], [ 1280, 900 ], [ 1440, 900 ] ].each do |width, height|
    test "the plants list's status chips, columns and rows are audited at #{width} (#614)" do
      sites = [ [ "Big Generating Station with a Very Long Official Name", "operating", "power_reactor" ], [ "Test Rig", "under_construction", "research_reactor" ],
                [ "Future Plant", "planned", "power_reactor" ], [ "Closed Site", "shut_down", "power_reactor" ] ]
      sites.each_with_index do |(name, status, type), n|
        site = cite!(plant(name, facility_type: type, status:, city: "Oak Ridge", state: "TN"))
        cite!(plant("#{name} Unit 1", parent: site, capacity_mw: 1100 - n * 200, status:)) if n.zero?
      end
      plant("Bare Name")
      resize_viewport(width, height)
      visit companies_path(category: "plants")
      assert_selector ".nd-prow__name", minimum: 5
      assert_selector ".nd-statuschips .nd-chip", minimum: 4
      assert_empty page.evaluate_script(AUDIT)
      assert_equal width <= 1279, page.evaluate_script("getComputedStyle(document.querySelector('.nd-lines__head')).display === 'none'"), "the header row is desktop only"
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=, width, "nothing scrolls sideways"
    end
  end

  test "a plants row with no capacity has no stray dot before its location on phones, and a row with one has it" do
    big = cite!(plant("Dotted Station", facility_type: "power_reactor", status: "operating", city: "Oak Ridge", state: "TN"))
    cite!(plant("Dotted Station Unit 1", parent: big, capacity_mw: 900, status: "operating"))
    cite!(plant("Undotted Site", facility_type: "power_reactor", status: "shut_down", city: "Athens", state: "AL"))
    resize_viewport(390, 844)
    visit companies_path(category: "plants")
    before = ->(name) { page.evaluate_script("(() => { const row = [...document.querySelectorAll('a.nd-prow')].find((r) => r.textContent.includes('#{name}')); return getComputedStyle(row.querySelector('.nd-prow__place'), '::before').content })()") }
    assert_equal '"· "', before.("Dotted Station")
    assert_equal "none", before.("Undotted Site")
  end

  test "on desktop the location column has room after the right-aligned capacity (#614)" do
    cite!(plant("Roomy Station", facility_type: "power_reactor", status: "operating", city: "Oak Ridge", state: "TN"))
    resize_viewport(1440, 900)
    visit companies_path(category: "plants")
    gap = page.evaluate_script("(() => { const row = document.querySelector('a.nd-prow'); const place = row.querySelector('.nd-prow__place'); return parseFloat(getComputedStyle(place).paddingLeft) })()")
    assert_operator gap, :>=, 12, "the location has its own 12px of air"
    assert_empty page.evaluate_script(AUDIT), "a long location still fits on one line"
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
