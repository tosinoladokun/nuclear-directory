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
    tall = page.evaluate_script("[...document.querySelectorAll('.nd-chart__barname, .nd-chart__newstitle, .nd-chart__more, .nd-home__downloadlink span, .nd-chart__title')].filter(e => e.getBoundingClientRect().height > 50).map(e => e.textContent)")
    assert_empty tall, "at #{width}: one line each"
    cut = page.evaluate_script("[...document.querySelectorAll('.nd-chart__src, .nd-chart__more, .nd-chart__title')].filter(e => e.scrollWidth > e.clientWidth + 1).map(e => e.textContent)")
    assert_empty cut, "at #{width}: source lines, links and titles are never cut"
    sizes = page.evaluate_script("[...new Set([...document.querySelectorAll('.nd-chart__name')].map(e => getComputedStyle(e).fontSize))]")
    assert_equal [ width < 360 ? "13px" : "15px" ], sizes, "at #{width}: one chip size (Design, #920)" if sizes.any?
    chips = page.evaluate_script("[...document.querySelectorAll('.nd-chart__name')].filter(e => e.scrollWidth > e.clientWidth + 1).map(e => e.textContent)")
    assert_operator chips, :all?, ->(name) { name.start_with?("enCore") }, "at #{width}: only a name too long for the phone, with no short name, is cut: #{chips}"
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

  test "the operators set: no bar name is cut at 1440, 390 or 320 (Design, #920)" do
    OrganizationRole.delete_all # the fuel set has nothing to show, so the other set does
    offtaker = role("data_center_offtaker")
    { "Constellation" => 3, "Dominion Energy" => 2, "NextEra Energy" => 2, "Southern Nuclear" => 2, "Duke Energy" => 1,
      "Tennessee Valley Authority" => 1 }.each do |name, n|
      org = cite!(company(name, short_name: (name == "Tennessee Valley Authority" ? "TVA" : nil)))
      n.times do |i|
        site = cite!(plant("#{name} plant #{i}"))
        cite!(link(org, "operates", cite!(Facility.create!(name: "#{name} #{i} unit", parent: site, facility_type: "power_reactor", status: "operating", **verification(true)))))
      end
    end
    seller = cite!(company("Kairos Power"))
    %w[Amazon Microsoft].each do |name|
      cite!(link(cite!(company(name, roles: [ offtaker ])), "offtake_with", seller).tap { |deal| deal.update!(description: "Signed a power purchase agreement") })
    end
    vogtle = cite!(plant("Plant Vogtle"))
    { "Georgia Power" => 45.7, "Oglethorpe Power" => 30.0, "MEAG Power" => 22.7, "Dalton Utilities" => 1.6 }.each do |name, pct|
      cite!(link(cite!(company(name)), "owns", vogtle)).update!(ownership_pct: pct)
    end

    [ 1440, 390, 320 ].each do |width|
      resize_viewport(width, 844)
      visit root_path(home: "b")
      assert_equal "operators", boxes.first[0], "at #{width}"
      cut = page.evaluate_script("[...document.querySelectorAll('.nd-chart__barname')].filter(e => e.scrollWidth > e.clientWidth + 1).map(e => e.textContent)")
      assert_empty cut, "at #{width}: every operator, buyer and owner name whole"
      assert_one_line(width)
    end
  end
end
