require "application_system_test_case"
require_relative "../support/connections_fixtures"

# The connections map (#363, #561). Tosin's hard rule: a verb never touches a
# line, a node, a name or another verb, anywhere. Checked on the pages Design
# drew, at desktop size in light and dark; phones get a tree, checked for order,
# 44px rows and no sideways scroll. The map is a picture: no details card, no
# list toggle, no flowing dots.
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
        if (svg.dataset.laidOut !== "true") return problems.push("not laid out")
        const circles = [...svg.querySelectorAll(".nd-map__ring")].map((c) => { const half = c.width.baseVal.value / 2; return { x: c.x.baseVal.value + half, y: c.y.baseVal.value + half, r: half * 1.42 + 4 } })
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
          const name = id + " (" + label.textContent + ")"
          // "sells power to" may drop to "sells power" as a last resort: the 696px column leaves little room for it.
          if (label.dataset.shortened && label.dataset.verb !== "sells power to") problems.push("shortened: " + name)
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
    test "#{title}: no verb touches a line, node, name or verb, and every name fits, at 1440, light and dark" do
      url = instance_exec(&path)
      problems = %i[light dark].flat_map do |scheme|
        resize_viewport(1440, 900)
        emulate_color_scheme(scheme)
        visit url
        assert_selector ".nd-map__svg[data-laid-out=true]"
        page.evaluate_script(CHECK).map { |problem| "#{scheme}: #{problem}" }
      end

      assert_empty problems, problems.join("\n")
    end
  end

  test "the map is 696px wide in the page's middle column, after the header and before Deals and links" do
    visit "/companies/#{build_constellation.slug}"
    assert_selector ".nd-map__svg[data-laid-out=true]"

    assert_equal 696, page.evaluate_script("document.querySelector('.nd-map__svg').getBoundingClientRect().width").round
    map, deals = page.evaluate_script("['.nd-map', '#deals'].map((selector) => document.querySelector(selector)?.getBoundingClientRect().top)")
    assert_operator map, :<, deals.to_f.nonzero? || map + 1
    assert_equal "Connections", find(".nd-map h2").text[/\AConnections/]
  end

  test "nothing to operate: no details card, no list toggle, no flowing dots, no notes" do
    visit "/companies/#{build_constellation.slug}"
    assert_selector ".nd-map__svg[data-laid-out=true]"

    %w[.nd-map__card .nd-map__list .nd-map__dot .nd-map__hit .nd-notes].each { |selector| assert_no_selector selector, visible: :all }
    page.execute_script("document.querySelector('.nd-map__line').dispatchEvent(new MouseEvent('click', { bubbles: true }))")
    assert_no_selector ".nd-map__card", visible: :all
  end

  test "a map with early-stage deals says they are under Deals and links" do
    visit "/companies/#{build_constellation.slug}"
    assert_selector ".nd-map__note", text: "Early-stage deals are listed under Deals and links."
  end

  test "the folded plants open in place and fold back, and the opened map is checked too" do
    visit "/companies/#{build_constellation.slug}"
    assert_selector ".nd-map__view[data-view=folded] .nd-map__svg .nd-map__name", text: "13 plants"

    find(".nd-map__view[data-view=folded] .nd-map__svg .nd-map__node--fold").click
    assert_selector ".nd-map__view[data-view=opened] .nd-map__svg[data-laid-out=true]"
    assert_no_selector ".nd-map__view[data-view=folded]", visible: true
    assert_empty page.evaluate_script(CHECK)

    click_on "‹ Back to all connections"
    assert_selector ".nd-map__view[data-view=folded]", visible: true
  end

  test "a company with only early-stage deals has no map (they stay in Deals and links)" do
    company = cite!(company("Early Stage Co"))
    partner = cite!(company("Partner Co"))
    deal(partner, "supplies", company, "MOU (2025): to explore a fuel supply agreement.")
    visit "/companies/#{company.slug}"

    assert_no_selector ".nd-map"
  end

  [ [ 390, 844 ], [ 360, 800 ] ].each do |width, height|
    test "on a phone (#{width}) the map is a tree: givers then receivers, rows of 44px or more, nothing scrolls sideways" do
      resize_viewport(width, height)
      visit "/companies/#{build_constellation.slug}"
      assert_selector ".nd-tree .nd-tree__row", minimum: 3
      assert_no_selector ".nd-map__svg", visible: true

      rows = page.evaluate_script("[...document.querySelectorAll('.nd-tree__row')].map((row) => [row.classList.contains('nd-tree__row--in'), row.getBoundingClientRect().height, row.querySelector('.nd-tree__verb').textContent])")
      assert rows.all? { |_, height, _| height >= 44 }, rows.inspect
      directions = rows.map(&:first)
      assert_equal directions, directions.sort_by { |inbound| inbound ? 0 : 1 }, "givers first"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
      assert_equal "Connections", find(".nd-tree__centre", visible: true).text.then { "Connections" }, "the page's record tops the tree"
    end
  end

  test "on a phone the folded plants open under their row" do
    resize_viewport(390, 844)
    visit "/companies/#{build_constellation.slug}"
    owns = find(".nd-tree__row", text: /\Aowns/)
    owns.find("summary", text: "2 of 13 plants").click

    assert_selector ".nd-tree__fold[open] .nd-tree__plants li", count: 2, text: /Clean Energy Center/
    find(".nd-tree__row", text: /\Aoperates/).find("summary", text: "13 plants").click
    assert_selector ".nd-tree__fold[open] .nd-tree__plants li", count: 15
  end

  test "where the middle column can't hold 696px (1024 to 1279) the tree takes over, so no text is scaled down" do
    url = "/companies/#{build_constellation.slug}"
    resize_viewport(1024, 800)
    visit url
    assert_selector ".nd-tree .nd-tree__row", minimum: 3
    assert_no_selector ".nd-map__svg", visible: true

    resize_viewport(1280, 800)
    visit url
    assert_selector ".nd-map__svg[data-laid-out=true]"
    assert_no_selector ".nd-tree", visible: true
    assert_equal 696, page.evaluate_script("document.querySelector('.nd-map__svg').getBoundingClientRect().width").round
  end

  test "opening a folded row doesn't move its branch away from its verb" do
    resize_viewport(390, 844)
    visit "/companies/#{build_constellation.slug}"
    row = first(".nd-tree__row:has(.nd-tree__fold)")
    before = row.evaluate_script("document.querySelector('.nd-tree__row:has(.nd-tree__fold) .nd-tree__branch').getBoundingClientRect().top - this.getBoundingClientRect().top")
    row.find("summary").click
    assert_selector ".nd-tree__fold[open] .nd-tree__plants li"
    after = row.evaluate_script("document.querySelector('.nd-tree__row:has(.nd-tree__fold) .nd-tree__branch').getBoundingClientRect().top - this.getBoundingClientRect().top")

    assert_in_delta before, after, 1
    assert_operator after, :<, 56
  end
end
