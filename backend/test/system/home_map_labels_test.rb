require "application_system_test_case"
require_relative "../support/directory_builders"

# Homepage B's map (#940): hovering or tapping a dot shows the plant's name and its state just above it, on one
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

  def touch(name, dx: 0)
    page.execute_script(<<~JS)
      const box = document.querySelector("circle[data-name='#{name}']").getBoundingClientRect()
      const x = box.left + box.width / 2 + #{dx}, y = box.top + box.height / 2, target = document.elementFromPoint(x, y)
      target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", clientX: x, clientY: y }))
      target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: y }))
    JS
  end

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
    touch("Byron", dx: 10)
    assert_equal [ "Byron", "Illinois" ], label["text"]
    assert_current_path root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")
    page.execute_script("document.body.click()")
    assert_nil label
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0
  end

  test "the label can be hovered (WCAG 1.4.13): it stays while the pointer moves onto it, then hides; Escape hides it" do
    open_map(1440)
    dot("Byron").hover
    find(".nd-chartmap__label").hover
    assert_equal [ "Byron", "Illinois" ], label["text"], "still open with the pointer on the label"
    find(".nd-chart__title", match: :first).hover
    assert_no_selector ".nd-chartmap__label:not([hidden])", wait: 2

    dot("Byron").hover
    find("body").send_keys(:escape)
    assert_nil label
  end

  test "a label left open when the page is cached is closed, or can be closed, when the page comes back" do
    open_map(1440)
    dot("Seabrook").click
    assert label
    page.execute_script("Turbo.visit('/privacy')")
    assert_current_path "/privacy"
    page.go_back
    assert_selector ".nd-chartmap-wrap[data-controller=home-map]"
    # Whether Turbo or the browser's back cache restores the page, a label still showing can be dismissed.
    page.execute_script("document.body.click()")
    assert_nil label
    assert_no_selector ".nd-chartmap__dot.is-active"

    # A Turbo snapshot taken with a label open comes back closed.
    dot("Seabrook").click
    page.execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")
    assert_nil label
    dot("Seabrook").click
    page.execute_script(<<~JS)
      const wrap = document.querySelector(".nd-chartmap-wrap")
      wrap.removeAttribute("data-controller")
    JS
    page.execute_script("document.querySelector('.nd-chartmap-wrap').setAttribute('data-controller', 'home-map')")
    assert_no_selector ".nd-chartmap__label:not([hidden])"
    assert_no_selector ".nd-chartmap__dot.is-active"
  end

  test "an open label moves with the map when the window narrows" do
    open_map(1440)
    dot("Seabrook").click
    resize_viewport(375, 900)
    assert_operator label["right"], :>=, 0, "still inside the card"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0
  end

  test "touch: a second tap on the same dot hides its label; a tap on another dot moves it" do
    open_map(375)
    touch("Byron")
    assert_equal [ "Byron", "Illinois" ], label["text"]
    touch("Seabrook")
    assert_equal [ "Seabrook", "New Hampshire" ], label["text"]
    touch("Seabrook", dx: 4)
    assert_nil label
    assert_current_path root_path(home: "b", charts: "plant_map,reactor_sizes,reactor_types")
  end

  test "a middle click on a dot doesn't open the card's page in a new tab" do
    open_map(1440)
    prevented = page.evaluate_script(<<~JS)
      (() => {
        const event = new MouseEvent("auxclick", { bubbles: true, cancelable: true, button: 1 })
        document.querySelector("circle[data-name='Byron']").dispatchEvent(event)
        return event.defaultPrevented
      })()
    JS
    assert prevented
  end
end
