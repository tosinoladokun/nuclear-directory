require "application_system_test_case"
require_relative "../support/directory_builders"

# Homepage B's layout (#909): at 1440 the large card on the left and the two small ones stacked on its right, as tall as
# it; on phones one column, large first. Nothing scrolls sideways and every name stays on one line.
class HomeBLayoutTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    fuel = role("fuel")
    steps = %w[mining conversion enrichment fabrication].to_h { |key| [ key, role(key, parent: fuel) ] }
    { "mining" => [ "Energy Fuels", "Ur-Energy", "enCore Energy Corporation of Wyoming and Texas" ], "conversion" => [ "ConverDyn" ],
      "enrichment" => [ "Centrus Energy", "Urenco", "Orano Enrichment USA, LLC" ], "fabrication" => [ "Global Nuclear Fuel–Americas", "TRISO-X" ] }
      .each { |step, names| names.each { |name| cite!(company(name, roles: [ steps.fetch(step) ])) } }
  end

  def boxes = page.evaluate_script("[...document.querySelectorAll('.nd-chart')].map(c => { const r = c.getBoundingClientRect(); return [c.dataset.homeChart, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.bottom)] })")

  def assert_one_line(width)
    tall = page.evaluate_script("[...document.querySelectorAll('.nd-chart__name, .nd-chart__barname, .nd-chart__newstitle, .nd-chart__more, .nd-home__downloadlink span')].filter(e => e.getBoundingClientRect().height > 30).map(e => e.textContent)")
    assert_empty tall, "at #{width}: one line each"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0, "at #{width}: no sideways scroll"
  end

  test "1440: large left, two small stacked right and as tall; 390: one column, large first" do
    resize_viewport(1440, 900)
    visit root_path(home: "b")
    large, first, second = boxes
    assert_equal "fuel", large[0]
    assert_operator first[1], :>, large[1] + large[3], "small cards sit right of the large one"
    assert_equal first[1], second[1]
    assert_operator second[2], :>, first[4], "stacked"
    assert_in_delta large[4], second[4], 1, "the column is as tall as the large card"
    assert_one_line(1440)

    [ 390, 320 ].each do |width|
      resize_viewport(width, 844)
      visit root_path(home: "b")
      cards = boxes
      assert_equal "fuel", cards.first[0], "at #{width}: large first"
      assert_equal 1, cards.map { |card| card[1] }.uniq.size, "at #{width}: one column"
      assert_one_line(width)
    end
  end
end
