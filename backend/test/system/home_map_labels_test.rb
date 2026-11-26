require "application_system_test_case"
require_relative "../support/directory_builders"

# Homepage B's map (#940, #949): hovering, tapping or focusing a dot shows the plant's name and its state just above it,
# on one line each, moved inward near the card's edges. Each dot is a link to its plant, and so is its label: a mouse
# click opens it, a touch opens it on the second tap. A shared dot's label is a chooser. The map is one tab stop.
class HomeMapLabelsTest < ApplicationSystemTestCase
  include DirectoryBuilders

  HOME = { home: "b", charts: "plant_map,reactor_sizes,reactor_types" }.freeze

  setup do
    operating_plant("Byron", state: "IL", latitude: 42.07, longitude: -89.28)
    # A BWR too, so the set asked for is a whole one (the split bar needs two types) and the map shows whatever the day.
    operating_plant("Columbia Generating Station", state: "WA", latitude: 46.47, longitude: -119.33, units: [ [ 1100.0, "BWR" ] ])
    operating_plant("Seabrook", state: "NH", latitude: 42.90, longitude: -70.85)
    operating_plant("PSEG Salem Generating Station", state: "NJ", latitude: 39.4625, longitude: -75.5358).update_columns(short_name: "Salem")
    operating_plant("PSEG Hope Creek Generating Station", state: "NJ", latitude: 39.4666, longitude: -75.5377).update_columns(short_name: "Hope Creek")
  end

  def open_map(width)
    resize_viewport(width, 900)
    visit root_path(HOME)
    assert_selector ".nd-chartmap-wrap[data-controller=home-map] .nd-chartmap__link[tabindex='0']"
  end

  def slug(name) = Facility.find_by(name:, parent_id: nil).slug

  def dot(name) = find("a.nd-chartmap__link[data-name='#{name}'] circle")

  def touch(name, dx: 0)
    page.execute_script(<<~JS)
      const box = document.querySelector("a[data-name='#{name}'] circle").getBoundingClientRect()
      const x = box.left + box.width / 2 + #{dx}, y = box.top + box.height / 2, target = document.elementFromPoint(x, y)
      target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", button: 0, clientX: x, clientY: y }))
      target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: y }))
    JS
  end

  def label = page.evaluate_script(<<~JS)
    (() => {
      const label = document.querySelector(".nd-chartmap__label"), wrap = label.parentElement.getBoundingClientRect()
      if (label.hidden) return null
      const box = label.getBoundingClientRect(), dot = document.querySelector(".nd-chartmap__spot.is-active circle")
      return { text: label.innerText.split("\\n"), left: box.left - wrap.left, right: wrap.right - box.right,
        above: dot.getBoundingClientRect().top - box.bottom, height: box.height, drawn: getComputedStyle(dot).r,
        links: [...label.querySelectorAll("a")].map((a) => [ a.getAttribute("href"), a.innerText.split("\\n")[0], a.classList.contains("is-muted") ]) }
    })()
  JS

  def focused = page.evaluate_script("document.activeElement.dataset.name || document.activeElement.className")

  test "hover: the name and full state above the dot, the dot grown, the label a link; a click opens the plant" do
    open_map(1440)
    dot("Byron").hover
    shown = label
    assert_equal [ "Byron", "Illinois" ], shown["text"]
    assert_operator shown["above"], :>=, 0, "the label sits above the dot"
    assert_operator shown["height"], :<, 60, "two lines, neither wrapped"
    assert_equal "9px", shown["drawn"], "r 7 to 9"
    assert_equal [ [ "/plants/#{slug('Byron')}", "Byron", false ] ], shown["links"], "the whole label is one link"

    dot("Byron").click
    assert_current_path "/plants/#{slug('Byron')}"
  end

  test "a click on the map off the dots only hides the label; the title opens the list" do
    open_map(1440)
    dot("Byron").hover
    find(".nd-chartmap__land", match: :first).click
    assert_nil label
    assert_current_path root_path(HOME)
    find("[data-home-chart=plant_map] .nd-chart__head").click
    assert_current_path "/companies?category=plants&status=operating"
  end

  test "a shared dot: a chooser, a linked name per line and the state once; a click keeps it open, a name opens it" do
    open_map(1440)
    dot("Salem").hover
    shown = label
    assert_equal [ "Hope Creek", "Salem", "New Jersey" ], shown["text"]
    assert_equal [ [ "/plants/#{slug('PSEG Hope Creek Generating Station')}", "Hope Creek", false ], [ "/plants/#{slug('PSEG Salem Generating Station')}", "Salem", false ] ], shown["links"]

    dot("Salem").click
    assert_current_path root_path(HOME)
    find(".nd-chart__title", match: :first).hover
    sleep 0.5 # past the label's linger
    assert label, "a clicked chooser stays open"
    find(".nd-chartmap__label a", text: "Salem").click
    assert_current_path "/plants/#{slug('PSEG Salem Generating Station')}"
  end

  test "375: a tap shows the label inside the card at both edges and stays; a tap outside the card hides it" do
    open_map(375)
    { "Columbia Generating Station" => "Washington", "Seabrook" => "New Hampshire" }.each do |name, state|
      touch(name)
      shown = label
      assert_equal [ name, state ], shown["text"]
      assert_operator shown["left"], :>=, 0, "#{name}: not cut on the left"
      assert_operator shown["right"], :>=, 0, "#{name}: not cut on the right"
      assert_operator shown["height"], :<, 60, "#{name}: one line each"
    end
    assert_current_path root_path(HOME)
    page.execute_script("document.body.click()")
    assert_nil label

    # A finger that lands just beside a dot (a dot is 6px wide on a phone) still picks it, and stays on the page.
    touch("Byron", dx: 10)
    assert_equal [ "Byron", "Illinois" ], label["text"]
    assert_current_path root_path(HOME)
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0
  end

  test "touch: a tap on another dot moves the label; a second tap on the same dot opens its plant" do
    open_map(375)
    touch("Byron")
    touch("Seabrook")
    assert_equal [ "Seabrook", "New Hampshire" ], label["text"]
    touch("Seabrook", dx: 4)
    assert_current_path "/plants/#{slug('Seabrook')}"
  end

  test "touch: a second tap on the label opens the plant; on a shared dot, the tap on a name" do
    open_map(375)
    touch("Salem")
    touch("Salem")
    assert_equal [ "Hope Creek", "Salem", "New Jersey" ], label["text"], "a second tap on a shared dot keeps the chooser"
    find(".nd-chartmap__label a", text: "Hope Creek").click
    assert_current_path "/plants/#{slug('PSEG Hope Creek Generating Station')}"
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

  test "keyboard: the map is one tab stop; arrows go west to east, End to the last; Enter opens the plant" do
    open_map(1440)
    assert_equal 1, page.evaluate_script("document.querySelectorAll('.nd-chartmap__link[tabindex=\"0\"]').length")
    find("[data-home-chart=plant_map] .nd-chart__head").send_keys(:tab)
    assert_equal "Columbia Generating Station", focused, "the westernmost plant first"
    assert_equal [ "Columbia Generating Station", "Washington" ], label["text"]
    ring = page.evaluate_script("(() => { const r = document.querySelector('.nd-chartmap__ring'), d = document.activeElement.querySelector('circle'); return [ r.getAttribute('visibility'), r.getAttribute('cx') === d.getAttribute('cx'), r.getAttribute('r') ] })()")
    assert_equal [ "visible", true, "12" ], ring, "a focus ring drawn round the dot"

    page.send_keys(:right)
    assert_equal "Byron", focused
    page.send_keys(:right)
    assert_equal "Hope Creek", focused
    assert_equal [ [ "Hope Creek", false ], [ "Salem", true ] ], label["links"].map { |_, name, muted| [ name, muted ] }, "the focused name in ink"
    page.send_keys(:right)
    assert_equal "Salem", focused, "each plant on a shared dot is its own stop"
    page.send_keys(:end)
    assert_equal "Seabrook", focused
    page.send_keys(:tab)
    assert_not_equal "nd-chartmap__link", page.evaluate_script("document.activeElement.getAttribute('class')"), "one tab leaves the map"

    page.send_keys([ :shift, :tab ])
    assert_equal "Seabrook", focused, "back to the plant last focused"
    page.send_keys(:enter)
    assert_current_path "/plants/#{slug('Seabrook')}"
  end

  test "the analytics: a tap that shows a label counts nothing; the tap that opens a plant is a record click" do
    open_map(375)
    events = page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      import("analytics").then((m) => {
        m.installHomeTracking()
        document.querySelector(".nd-chartmap__label").addEventListener("click", (event) => event.preventDefault()) // stay on the page
        const tap = () => {
          const box = document.querySelector("a[data-name='Byron'] circle").getBoundingClientRect()
          const x = box.left + box.width / 2, y = box.top + box.height / 2, target = document.elementFromPoint(x, y)
          target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", button: 0, clientX: x, clientY: y }))
          target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: y }))
        }
        tap()
        const first = m.pendingHomeEvents().map((event) => event[0])
        tap()
        done(JSON.stringify({ first, all: m.pendingHomeEvents() }))
      })
    JS
    result = JSON.parse(events)
    assert_equal %w[home_viewed], result["first"]
    assert_equal [ "home_record_click", { "chart" => "plant_map", "kind" => "plant", "home_variant" => "B", "home_variant_forced" => true } ], result["all"].last
  end

  test "a label left open when the page is cached is closed, or can be closed, when the page comes back" do
    open_map(1440)
    dot("Salem").click
    assert label
    find(".nd-chart__title", match: :first).hover # the pointer off the dot, or the restored page's hover reopens its label
    page.execute_script("Turbo.visit('/privacy')")
    assert_current_path "/privacy"
    page.go_back
    assert_selector ".nd-chartmap-wrap[data-controller=home-map]"
    # Whether Turbo or the browser's back cache restores the page, a label still showing can be dismissed.
    page.execute_script("document.body.click()")
    assert_no_selector ".nd-chartmap__label:not([hidden])"
    assert_no_selector ".nd-chartmap__spot.is-active"

    # A Turbo snapshot taken with a label open comes back closed.
    dot("Salem").click
    page.execute_script("document.dispatchEvent(new Event('turbo:before-cache'))")
    assert_nil label
    dot("Salem").click
    page.execute_script("document.querySelector('.nd-chartmap-wrap').removeAttribute('data-controller')")
    page.execute_script("document.querySelector('.nd-chartmap-wrap').setAttribute('data-controller', 'home-map')")
    assert_no_selector ".nd-chartmap__label:not([hidden])"
    assert_no_selector ".nd-chartmap__spot.is-active"
    # The same instance reconnects; it forgets the dot it had open, so hovering that dot opens it again (Copilot, #953).
    find(".nd-chart__title", match: :first).hover
    dot("Salem").hover
    assert_equal [ "Hope Creek", "Salem", "New Jersey" ], label["text"]
  end

  test "a touch that turns into a scroll leaves nothing behind: Enter on a focused plant opens it (Copilot, #953)" do
    open_map(375)
    page.execute_script(<<~JS)
      const box = document.querySelector("a[data-name='Byron'] circle").getBoundingClientRect()
      const x = box.left + box.width / 2, y = box.top + box.height / 2, target = document.elementFromPoint(x, y)
      target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", button: 0, clientX: x, clientY: y }))
      target.dispatchEvent(new PointerEvent("pointercancel", { bubbles: true, pointerType: "touch" }))
    JS
    assert_no_selector "[data-map-tap]"
    find("[data-home-chart=plant_map] .nd-chart__head").send_keys(:tab)
    page.send_keys(:end)
    assert_equal "Seabrook", focused
    page.send_keys(:enter)
    assert_current_path "/plants/#{slug('Seabrook')}"
  end

  test "touch: a second tap beside the dot opens it even if the dot lost focus in between (Copilot, #953)" do
    open_map(375)
    touch("Byron")
    page.execute_script(<<~JS)
      document.querySelector("a[data-name='Byron']").focus()
      const box = document.querySelector("a[data-name='Byron'] circle").getBoundingClientRect()
      const x = box.left + box.width / 2 + 10, y = box.top + box.height / 2, target = document.elementFromPoint(x, y)
      target.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true, pointerType: "touch", button: 0, clientX: x, clientY: y }))
      document.activeElement.blur() // the tap beside the dot takes focus off it, which closes the label
      target.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, clientX: x, clientY: y }))
    JS
    assert_current_path "/plants/#{slug('Byron')}"
  end

  test "an open label moves with the map when the window narrows" do
    open_map(1440)
    dot("Salem").click # a chooser stays open
    resize_viewport(375, 900)
    assert_equal [ "Hope Creek", "Salem", "New Jersey" ], label["text"]
    assert_operator label["right"], :>=, 0, "still inside the card"
    assert_operator page.evaluate_script("document.documentElement.scrollWidth - innerWidth"), :<=, 0
  end
end
