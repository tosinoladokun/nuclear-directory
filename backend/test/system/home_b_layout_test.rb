require "application_system_test_case"
require_relative "../support/directory_builders"

# Homepage B's layout (#909): at 1440 the large card on the left and the two small ones stacked on its right, as tall as
# it; on phones one column, large first. Every title, name and axis label stays on one line, and nothing scrolls
# sideways, for every card in the pool.
class HomeBLayoutTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    { "Illinois" => [ "IL", 42.07, -89.28 ], "Georgia" => [ "GA", 33.14, -81.76 ], "Alabama" => [ "AL", 34.70, -87.12 ],
      "Pennsylvania" => [ "PA", 40.15, -76.72 ], "North Carolina" => [ "NC", 35.63, -78.96 ], "South Carolina" => [ "SC", 34.40, -81.32 ],
      "Tennessee" => [ "TN", 35.60, -84.79 ], "Texas" => [ "TX", 28.79, -96.05 ], "Arizona" => [ "AZ", 33.39, -112.86 ] }
      .each_with_index do |(name, (state, lat, lon)), i|
        operating_plant("#{name} Generating Station", state:, latitude: lat, longitude: lon,
          units: Array.new(i % 4 + 1) { |n| [ 560.0 + 180 * ((i + n) % 5), n.even? ? "PWR" : "BWR" ] })
      end
    cite!(plant("Kewaunee", facility_type: "power_reactor", status: "decommissioning"))
    vendor = cite!(organizations(:westinghouse).tap { |org| org.update_columns(short_name: "Westinghouse", **verification(true)) })
    Facility.where(parent_id: nil).find_each { |site| cite!(link(vendor, "vendor_for", site)) }
  end

  def boxes = page.evaluate_script("[...document.querySelectorAll('.nd-chart')].map(c => { const r = c.getBoundingClientRect(); return [c.dataset.homeChart, Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.bottom)] })")

  def assert_tidy(width)
    tall = page.evaluate_script("[...document.querySelectorAll('.nd-chart__title, .nd-chartbars__label, .nd-chartsplit__label, .nd-axis__name, .nd-chartcols__xlabel, .nd-home__downloadlink span')].filter(e => e.getBoundingClientRect().height > 30).map(e => e.textContent)")
    assert_empty tall, "at #{width}: one line each"
    cut = page.evaluate_script("[...document.querySelectorAll('.nd-chart__title, .nd-chartbars__label, .nd-chartsplit__label')].filter(e => e.scrollWidth > e.clientWidth + 1 && !e.hasAttribute('data-truncate')).map(e => e.textContent)")
    assert_empty cut, "at #{width}: no title or label is cut; only a plant's or company's name may end in an ellipsis"
    names = page.evaluate_script("[...document.querySelectorAll('.nd-chartbars__label[data-truncate]')].filter(e => !e.title).length")
    assert_equal 0, names, "at #{width}: a cut name keeps its full name in the title"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0, "at #{width}: no sideways scroll"
  end

  test "1440: large left, two small stacked right and as tall; phones: one column, large first" do
    resize_viewport(1440, 900)
    visit root_path(home: "b", charts: "plant_map,state_power,reactor_sizes")
    large, first, second = boxes
    assert_equal "plant_map", large[0]
    assert_operator first[1], :>, large[1] + large[3], "small cards sit right of the large one"
    assert_equal first[1], second[1]
    assert_operator second[2], :>, first[4], "stacked"
    assert_in_delta large[4], second[4], 1, "the column is as tall as the large card"

    visit root_path(home: "b", charts: "largest_plants,state_reactors,reactor_sizes")
    gaps = page.evaluate_script("[...document.querySelectorAll('.nd-chart')].map(c => Math.round(c.querySelector('.nd-chart__body').getBoundingClientRect().top - c.querySelector('.nd-chart__head').getBoundingClientRect().bottom))")
    assert_equal [ 16, 16, 16 ], gaps, "every chart 16px under its title, the large one too (Design, #935)"

    [ 390, 320 ].each do |width|
      resize_viewport(width, 844)
      visit root_path(home: "b", charts: "plant_map,state_power,reactor_sizes")
      cards = boxes
      assert_equal "plant_map", cards.first[0], "at #{width}: large first"
      assert_equal 1, cards.map { |card| card[1] }.uniq.size, "at #{width}: one column"
      visit root_path(home: "b", charts: "largest_plants,state_reactors,reactor_sizes")
      sizes = page.evaluate_script("[...new Set([...document.querySelectorAll('.nd-chartbars__label')].map(e => getComputedStyle(e).fontSize))]")
      assert_equal [ "13px" ], sizes, "at #{width}: bar names 13px on every card under 520px (Design, #935)"
      shown = page.evaluate_script("getComputedStyle(document.querySelector('[data-home-chart=reactor_sizes] .nd-chart__title')).display !== 'none' && document.querySelector('[data-home-chart=reactor_sizes] .nd-chart__title').innerText")
      assert_equal "How big are US reactors?", shown, "at #{width}: the whole question where it fits"
    end
  end

  test "every card in the pool, large and small, at 1440, 390 and 320" do
    # A few sets that between them show every question in every slot it can take.
    covering = HomeCharts::POOL.select(&:large?).flat_map do |large|
      todo = HomeCharts::POOL.select(&:small?) - [ large ]
      HomeCharts.sets.select { |set| set.first == large }.filter_map do |set|
        next if (set.drop(1) & todo).empty?

        todo -= set
        set
      end
    end
    assert_equal HomeCharts::POOL.select(&:small?).map(&:key).sort, covering.flat_map { |set| set.drop(1) }.map(&:key).uniq.sort

    [ 1440, 390, 320 ].each do |width|
      resize_viewport(width, 844)
      covering.each do |set|
        visit root_path(home: "b", charts: set.map(&:key).join(","))
        assert_equal set.map { |question| question.key.to_s }, boxes.map(&:first), "at #{width}: the set asked for"
        assert_tidy("#{width}, #{set.map(&:key).join(', ')}")
      end
    end
  end
end
