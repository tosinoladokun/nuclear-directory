require "application_system_test_case"
require_relative "../support/directory_builders"

# Homepage B's records link to their pages (#949): a bar row that is a plant or a company is one link, on a subgrid so
# its columns stay as they were; on hover it fills with sunken paper and its bar mixes with ink; on focus, the standard
# ring. The card's title row links to the list. Each click tells the analytics which.
class HomeChartLinksTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    operating_plant("Plant Vogtle", state: "GA", units: [ [ 1150.0, "PWR" ], [ 1114.0, "PWR" ] ])
    operating_plant("Byron", units: [ [ 1164.0, "PWR" ] ])
    operating_plant("Dresden", units: [ [ 894.0, "BWR" ] ])
  end

  def rows = page.evaluate_script(<<~JS)
    [...document.querySelectorAll("[data-home-chart] .nd-chartbars")].map((chart) => ({
      names: [...chart.querySelectorAll(".nd-chartbars__label")].map((e) => Math.round(e.getBoundingClientRect().left)),
      bars: [...chart.querySelectorAll(".nd-chartbars__track")].map((e) => Math.round(e.getBoundingClientRect().left)),
      category: Math.round(chart.querySelector(".nd-chartbars__catname").getBoundingClientRect().left),
      heights: [...chart.querySelectorAll(".nd-chartbars__row")].map((e) => e.getBoundingClientRect().height) }))
  JS

  def style(selector, property, pseudo = nil) = page.evaluate_script("getComputedStyle(document.querySelector(#{selector.to_json}), #{pseudo.to_json}).#{property}")

  test "a linked row keeps the chart's columns; hover fills it and darkens its bar; focus rings it; a click opens the plant" do
    [ 1440, 375 ].each do |width|
      resize_viewport(width, 900)
      visit root_path(home: "b", charts: "largest_plants,state_power,reactor_types")
      rows.each do |chart|
        assert_equal [ chart["category"] ] * chart["names"].size, chart["names"], "at #{width}: every name at the axis name's left"
        assert_equal 1, chart["bars"].uniq.size, "at #{width}: every bar starts at the same place"
        assert chart["heights"].all? { |height| height >= 28 }, "at #{width}: rows at least 28px tall, above the 24px target"
      end
    end

    resize_viewport(1440, 900)
    visit root_path(home: "b", charts: "largest_plants,state_power,reactor_types")
    row = "[data-home-chart=largest_plants] a.nd-chartbars__row"
    plain = style("#{row} .nd-chartbars__bar", "backgroundColor")
    find(row, match: :first).hover
    sleep 0.2 # the 120ms fade
    assert_not_equal "rgba(0, 0, 0, 0)", style(row, "backgroundColor", "::before"), "the row fills on hover"
    assert_equal %w[-8px -8px], [ style(row, "left", "::before"), style(row, "right", "::before") ], "the fill 8px past the name and the value (Design QA, #953)"
    assert_not_equal plain, style("#{row} .nd-chartbars__bar", "backgroundColor"), "its bar mixes with ink"
    assert_equal "none", style(row, "textDecorationLine"), "no underline"
    assert_equal "none", style("[data-home-chart=state_power] .nd-chartbars__row", "content", "::before"), "a state row stays plain"

    find("[data-home-chart=largest_plants] .nd-chart__head").send_keys(:tab)
    assert page.evaluate_script("document.activeElement.matches('a.nd-chartbars__row:focus-visible')"), "the first row is the next stop"
    assert_equal [ "none", "solid" ], [ style(row, "outlineStyle"), style(row, "outlineStyle", "::before") ], "the standard ring, on the fill's box"

    first = Facility.find_by(name: "Plant Vogtle", parent_id: nil)
    find(row, match: :first).click
    assert_current_path "/plants/#{first.slug}"
  end

  test "the analytics: a row is a record click with its card and kind; the title is a card click" do
    resize_viewport(1440, 900)
    visit root_path(home: "b", charts: "largest_plants,state_power,reactor_types")
    events = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("analytics").then((m) => {
        m.installHomeTracking()
        for (const selector of ["[data-home-chart=largest_plants] a.nd-chartbars__row .nd-chartbars__bar", "[data-home-chart=state_power] .nd-chartbars__row .nd-chartbars__label", "[data-home-chart=largest_plants] .nd-chart__title"]) {
          const target = document.querySelector(selector)
          target.addEventListener("click", (event) => event.preventDefault()) // stay on the page
          target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }))
        }
        done(JSON.stringify(m.pendingHomeEvents()))
      })
    JS
    forced = { "home_variant" => "B", "home_variant_forced" => true }
    assert_equal [ [ "home_viewed", forced ],
      [ "home_record_click", { "chart" => "largest_plants", "kind" => "plant", **forced } ],
      [ "home_chart_click", { "chart" => "largest_plants", **forced } ] ], JSON.parse(events), "a state row counts nothing"
  end
end
