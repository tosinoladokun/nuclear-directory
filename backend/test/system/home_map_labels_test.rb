require "application_system_test_case"
require_relative "../support/directory_builders"

# Homepage B's map (#940): hovering, focusing or tapping a dot shows the plant's name and its state just above it, on one
# line each, moved inward near the card's edges. A dot isn't a link: clicking it never opens the card's page.
class HomeMapLabelsTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    operating_plant("Byron", state: "IL", latitude: 42.07, longitude: -89.28)
    operating_plant("Columbia Generating Station", state: "WA", latitude: 46.47, longitude: -119.33)
    operating_plant("Seabrook", state: "NH", latitude: 42.90, longitude: -70.85)
    operating_plant("PSEG Salem Generating Station", state: "NJ", latitude: 39.4625, longitude: -75.5358).update_columns(short_name: "Salem")
    operating_plant("PSEG Hope Creek Generating Station", state: "NJ", latitude: 39.4666, longitude: -75.5377).update_columns(short_name: "Hope Creek")
  end

  def open_map(width)
    resize_viewport(width, 900)
    visit root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")
    assert_selector ".nd-chartmap-wrap[data-controller=home-map]"
  end

  def dot(name) = find("circle.nd-chartmap__dot[data-name='#{name}']")

  def label = page.evaluate_script(<<~JS)
    (() => {
      const label = document.querySelector(".nd-chartmap__label"), wrap = label.parentElement.getBoundingClientRect()
      if (label.hidden) return null
      const box = label.getBoundingClientRect(), dot = document.querySelector(".nd-chartmap__dot.is-active").getBoundingClientRect()
      return { text: label.innerText.split("\\n"), left: box.left - wrap.left, right: wrap.right - box.right, above: dot.top - box.bottom,
        height: box.height, r: document.querySelector(".nd-chartmap__dot.is-active").getAttribute("r"),
        drawn: getComputedStyle(document.querySelector(".nd-chartmap__dot.is-active")).r }
    })()
  JS

  test "hover: the name and full state above the dot, the dot grown; clicking it stays on the page" do
    open_map(1440)
    dot("Byron").hover
    shown = label
    assert_equal [ "Byron", "Illinois" ], shown["text"]
    assert_operator shown["above"], :>=, 0, "the label sits above the dot"
    assert_operator shown["height"], :<, 60, "two lines, neither wrapped"
    assert_equal "9px", shown["drawn"], "r 7 to 9"

    dot("Byron").click
    assert_current_path root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")
    assert label, "a click shows the label too"

    find(".nd-chartmap__land", match: :first).click
    assert_nil label, "a click elsewhere on the map only hides it"
    assert_current_path root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")
  end

  test "plants on one spot share a label" do
    open_map(1440)
    dot("Hope Creek and Salem").hover
    assert_equal [ "Hope Creek and Salem", "New Jersey" ], label["text"]
  end

  test "keyboard: a focused dot shows its label, Escape hides it" do
    open_map(1440)
    page.execute_script("document.querySelector(\"circle[data-name='Seabrook']\").focus()")
    assert_equal [ "Seabrook", "New Hampshire" ], label["text"]
    dot("Seabrook").send_keys(:escape)
    assert_nil label
  end

  test "375: a tap shows the label inside the card at both edges; a tap outside the card hides it" do
    open_map(375)
    { "Columbia Generating Station" => "Washington", "Seabrook" => "New Hampshire" }.each do |name, state|
      dot(name).click
      shown = label
      assert_equal [ name, state ], shown["text"]
      assert_operator shown["left"], :>=, 0, "#{name}: not cut on the left"
      assert_operator shown["right"], :>=, 0, "#{name}: not cut on the right"
      assert_operator shown["height"], :<, 60, "#{name}: one line each"
    end
    page.execute_script("document.body.click()")
    assert_nil label

    # A finger that lands just beside a dot (a dot is 6px wide on a phone) still picks it, and stays on the page.
    page.execute_script(<<~JS)
      const box = document.querySelector("circle[data-name='Byron']").getBoundingClientRect()
      const x = box.left + box.width / 2 + 10, y = box.top + box.height / 2, target = document.elementFromPoint(x, y)
      target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", clientX: x, clientY: y }))
      target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: y }))
    JS
    assert_equal [ "Byron", "Illinois" ], label["text"]
    assert_current_path root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")
    page.execute_script("document.body.click()")
    assert_nil label
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0
  end
end
