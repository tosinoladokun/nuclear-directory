require "application_system_test_case"
require_relative "../support/connections_fixtures"

# The connections map (#363). Tosin's hard rule: a verb never touches a
# line, a node, a name or another verb, anywhere. Checked on the three pages
# Design drew, at desktop and phone sizes, in light and dark.
class ConnectionsMapPageTest < ApplicationSystemTestCase
  include ConnectionsFixtures

  # Every visible verb against every node circle (+6px), name, other verb
  # (+4px) and the other lines, sampled every 4px; then each name: one
  # line, inside its slot, at or above its floor, uncut. Returns problems.
  # Names too long for one line that only a short name fixes ("DOE"): Data
  # Quality fills short_name (#399). Until then these may end in "…".
  WAITING = [ "U.S. Department of Energy", "Southern Nuclear Operating Company", "Global Nuclear Fuel–Americas" ].freeze

  CHECK = <<~JS.freeze
    (() => {
      const WAITING = #{WAITING.to_json}
      const problems = []
      document.querySelectorAll(".nd-map__svg").forEach((svg) => {
        if (svg.getClientRects().length === 0) return
        if (svg.dataset.laidOut !== "true") return problems.push("not laid out: " + svg.dataset.size)
        const circles = [...svg.querySelectorAll(".nd-map__ring")].map((c) => ({ x: c.cx.baseVal.value, y: c.cy.baseVal.value, r: c.r.baseVal.value + 6 }))
        const names = [...svg.querySelectorAll(".nd-map__name")]
        const labels = [...svg.querySelectorAll(".nd-map__label")].filter((l) => l.style.visibility !== "hidden")
        const lines = new Map()
        svg.querySelectorAll(".nd-map__edge").forEach((edge) => {
          const points = []
          edge.querySelectorAll(".nd-map__line").forEach((line) => {
            const length = line.getTotalLength()
            for (let at = 0; at <= length; at += 4) points.push(line.getPointAtLength(at))
          })
          lines.set(edge.dataset.group, points)
        })
        const overlap = (a, b, gap) => a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap && b.y < a.y + a.height + gap
        const inside = (p, b) => p.x >= b.x && p.x <= b.x + b.width && p.y >= b.y && p.y <= b.y + b.height
        labels.forEach((label, i) => {
          const box = label.getBBox()
          const id = label.dataset.group
          const name = svg.dataset.size + " " + id + " (" + label.textContent + ")"
          if (label.dataset.shortened) problems.push("shortened: " + name)
          circles.forEach((c) => {
            const x = Math.max(box.x, Math.min(c.x, box.x + box.width)), y = Math.max(box.y, Math.min(c.y, box.y + box.height))
            if (Math.hypot(c.x - x, c.y - y) < c.r) problems.push("touches a node: " + name)
          })
          names.forEach((n) => { if (overlap(box, n.getBBox(), 0)) problems.push("touches the name " + n.textContent + ": " + name) })
          labels.forEach((other, j) => { if (j !== i && overlap(box, other.getBBox(), 4)) problems.push("touches the verb " + other.dataset.group + ": " + name) })
          lines.forEach((points, group) => { if (group !== id && points.some((p) => inside(p, box))) problems.push("touches the line " + group + ": " + name) })
        })
        names.filter((n) => !WAITING.includes(n.querySelector("title").textContent)).forEach((n) => {
          const size = parseFloat(getComputedStyle(n).fontSize)
          if (n.getComputedTextLength() > Number(n.dataset.slot) + 0.5) problems.push("name past its slot: " + n.textContent)
          if (size < Number(n.dataset.floor)) problems.push("name below its floor: " + n.textContent)
          if ("truncate" in n.dataset) problems.push("name cut: " + n.textContent)
        })
      })
      return [...new Set(problems)]
    })()
  JS

  PAGES = {
    "Plant Vogtle" => -> { "/plants/#{build_vogtle.slug}" },
    "TerraPower" => -> { "/companies/#{build_terrapower.slug}" },
    "Constellation" => -> { "/companies/#{build_constellation.slug}" },
    # Owns and operates the same two plants: two bundles to the same nodes.
    "A utility that owns and runs two plants" => lambda {
      company = cite!(company("Two Plant Utility", roles: [ role("utility") ]))
      %w[North South].each do |name|
        site = cite!(plant("#{name} Station", facility_type: "power_reactor", status: "operating"))
        cite!(link(company, "owns", site))
        cite!(link(company, "operates", site))
      end
      "/companies/#{company.slug}"
    }
  }.freeze

  PAGES.each do |title, path|
    test "#{title}: no verb touches a line, node, name or verb, and every name fits, at 1440 and 390, light and dark" do
      url = instance_exec(&path)
      problems = [ [ 1440, 900 ], [ 390, 844 ] ].product(%i[light dark]).flat_map do |(width, height), scheme|
        resize_viewport(width, height)
        emulate_color_scheme(scheme)
        visit url
        assert_selector ".nd-map__svg[data-laid-out=true]"
        page.evaluate_script(CHECK).map { |problem| "#{width} #{scheme}: #{problem}" }
      end

      assert_empty problems, problems.join("\n")
    end
  end

  test "the folded plants open in place and fold back, and the opened map is checked too" do
    visit "/companies/#{build_constellation.slug}"
    assert_selector ".nd-map__view[data-view=folded] .nd-map__svg--wide .nd-map__name", text: "13 plants"

    find(".nd-map__view[data-view=folded] .nd-map__svg--wide .nd-map__node--fold").click
    assert_selector ".nd-map__view[data-view=opened] .nd-map__svg--wide[data-laid-out=true]"
    assert_no_selector ".nd-map__view[data-view=folded]", visible: true
    assert_empty page.evaluate_script(CHECK)

    click_on "‹ Back to all connections"
    assert_selector ".nd-map__view[data-view=folded]", visible: true
  end

  test "on a phone, Back folds the plants again and puts focus on the visible fold node" do
    resize_viewport(390, 844)
    visit "/companies/#{build_constellation.slug}"
    find(".nd-map__view[data-view=folded] .nd-map__svg--narrow .nd-map__node--fold").click
    assert_selector ".nd-map__view[data-view=opened] .nd-map__svg--narrow[data-laid-out=true]"

    click_on "‹ Back to all connections"
    assert_equal "narrow", page.evaluate_script("document.activeElement.closest('svg')?.dataset.size")
    assert_equal "13 plants. Show them", page.evaluate_script("document.activeElement.getAttribute('aria-label')")
  end

  test "a company with only early-stage deals shows its Notes without a map" do
    company = cite!(company("Early Stage Co"))
    partner = cite!(company("Partner Co"))
    deal(partner, "supplies", company, "MOU (2025): to explore a fuel supply agreement.")
    visit "/companies/#{company.slug}"

    within ".nd-map" do
      assert_selector ".nd-notes__stage", text: "MOU · 2025"
      assert_link "Partner Co"
      assert_text "Partner Co: To explore a fuel supply agreement."
      assert_no_selector "svg", visible: :all
    end
  end

  test "a line's details: shown on hover, kept on click, closed with Esc; with its source" do
    visit "/plants/#{build_vogtle.slug}"
    assert_selector ".nd-map__svg--wide[data-laid-out=true]"

    owns = find(".nd-map__svg--wide .nd-map__hit[aria-label^='Dalton Utilities, Georgia Power, MEAG Power, and Oglethorpe Power Corporation own Plant Vogtle']")
    owns.click
    within ".nd-map__card" do
      assert_text "4 companies → Plant Vogtle"
      assert_link "Georgia Power"
      assert_text "45.7% share"
      assert_link "See the source", href: "https://example.org/source", count: 4
    end
    assert_selector ".nd-map__svg--wide .nd-map__edge.is-on", count: 1

    find("body").send_keys(:escape)
    assert_no_selector ".nd-map__card", visible: true
  end

  test "one dot per arrow, none under reduced motion; the list version holds every connection" do
    visit "/plants/#{build_vogtle.slug}"
    assert_equal 4 + 1 + 1, all(".nd-map__svg--wide .nd-map__dot", visible: :all).size
    assert_equal "6", find(".nd-map h2 small").text[/\d+/]

    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-reduced-motion", value: "reduce" } ])
    visit current_path
    assert_equal [ "none" ], page.evaluate_script("[...new Set([...document.querySelectorAll('.nd-map__svg--wide .nd-map__dot')].map((d) => getComputedStyle(d).display))]")
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])

    find(".nd-map__list summary").click
    assert_selector ".nd-map__list li", count: 6
    assert_selector ".nd-map__list li", text: "Georgia Power owns Plant Vogtle: 45.7% share (example.org)"
  end

  test "on a phone the map comes after the key facts, nothing scrolls sideways, and a tap opens the sheet" do
    resize_viewport(390, 844)
    visit "/plants/#{build_vogtle.slug}"
    assert_selector ".nd-map__svg--narrow[data-laid-out=true]"

    order = page.evaluate_script("[document.querySelector('.nd-overview').getBoundingClientRect().top, document.querySelector('.nd-map').getBoundingClientRect().top]")
    assert_operator order[0], :<, order[1], "key facts first"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")

    southern = find(".nd-map__svg--narrow .nd-map__hit[aria-label^='Southern Nuclear']")
    southern.hover
    assert_no_selector ".nd-map__card", visible: true, wait: 0.5 # a hover never opens the sheet
    southern.click
    assert_selector ".nd-map__card", visible: true
    assert_selector ".nd-map__card", text: "Southern Nuclear Operating Company → Plant Vogtle"
    assert_equal "fixed", page.evaluate_script("getComputedStyle(document.querySelector('.nd-map__card')).position")
    find(".nd-map__card .nd-map__close").click
    assert_no_selector ".nd-map__card", visible: true
  end

  test "on desktop the map runs across both columns, above the key facts and lists" do
    visit "/plants/#{build_vogtle.slug}"
    map, facts = page.evaluate_script("[document.querySelector('.nd-map'), document.querySelector('.nd-overview')].map((el) => el.getBoundingClientRect().toJSON())")
    assert_operator map["bottom"], :<=, facts["top"]
    assert_operator map["width"], :>=, 940
  end
end
