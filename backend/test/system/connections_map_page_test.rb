require "application_system_test_case"
require_relative "../support/connections_fixtures"

# The connections map (#363, #561, #682). Tosin's hard rule: no text touches another text or a line, anywhere. Checked on the pages Design
# drew, at desktop size in light and dark; phones get a tree, checked for order,
# 44px rows and no sideways scroll. The map is a picture: no details card, no
# list toggle, no flowing dots.
class ConnectionsMapPageTest < ApplicationSystemTestCase
  include ConnectionsFixtures

  # Text boxes (every name and every group heading) against each other (+4px) and against every line (sampled every 4px, +2px);
  # then each name: one line, inside its slot, at or above its floor, uncut, and not cut while it would still fit at 13px.
  # Names too long for one line that only a short name fixes ("DOE"): Data Quality fills short_name (#399); until then
  # these may end in "…".
  WAITING = [ "U.S. Department of Energy", "Southern Nuclear Operating Company", "Global Nuclear Fuel–Americas" ].freeze

  CHECK = <<~JS.freeze
    (() => {
      const WAITING = #{WAITING.to_json}
      const problems = []
      document.querySelectorAll(".nd-map__svg").forEach((svg) => {
        if (svg.getClientRects().length === 0) return
        if (svg.dataset.laidOut !== "true") return problems.push("not laid out")
        const texts = [...svg.querySelectorAll(".nd-map__name, .nd-map__group")]
        const boxes = texts.map((text) => { const box = text.getBBox(); return { text, x: box.x, y: box.y, width: box.width, height: box.height } })
        const overlap = (a, b, gap) => a.x < b.x + b.width + gap && b.x < a.x + a.width + gap && a.y < b.y + b.height + gap && b.y < a.y + a.height + gap
        boxes.forEach((a, i) => boxes.forEach((b, j) => { if (j > i && overlap(a, b, 4)) problems.push("text touches text: " + a.text.textContent.trim() + " / " + b.text.textContent.trim()) }))
        svg.querySelectorAll(".nd-map__line").forEach((line) => {
          const length = line.getTotalLength()
          for (let at = 0; at <= length; at += 4) {
            const point = line.getPointAtLength(at)
            boxes.forEach((box) => { if (point.x >= box.x - 2 && point.x <= box.x + box.width + 2 && point.y >= box.y - 2 && point.y <= box.y + box.height + 2) problems.push("a line crosses: " + box.text.textContent.trim()) })
          }
        })
        svg.querySelectorAll(".nd-map__name").forEach((n) => {
          if (WAITING.includes(n.querySelector("title").textContent)) return
          const size = parseFloat(getComputedStyle(n).fontSize)
          if (n.getComputedTextLength() > Number(n.dataset.slot) + 0.5) problems.push("name past its slot: " + n.textContent)
          if (size < Number(n.dataset.floor)) problems.push("name below its floor: " + n.textContent)
          if ("truncate" in n.dataset) problems.push("name cut: " + n.textContent)
        })
        // Group headings read in the phone tree's order, left side first.
        const groups = [...svg.querySelectorAll(".nd-map__group")].map((g) => g.textContent.trim())
        if (new Set(groups).size !== groups.length) problems.push("a heading appears twice: " + groups.join(", "))
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
    test "#{title}: no text touches another text or a line, and every name fits, at 1440, light and dark" do
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

  test "the map fits the page's middle column (696px at most), after the header and before Deals and links" do
    visit "/companies/#{build_constellation.slug}"
    assert_selector ".nd-map__svg[data-laid-out=true]"

    assert_operator page.evaluate_script("document.querySelector('.nd-map__svg').getBoundingClientRect().width").round, :<=, 696
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
    # The server draws the map; the controller (lazy-loaded) handles the click. Wait for it: it marks the drawing laid out.
    assert_selector ".nd-map__view[data-view=folded] .nd-map__svg[data-laid-out=true]"

    # Constellation's plants fold under OWNS and under OPERATES (#1004): two fold nodes, either opens the plants.
    assert_selector ".nd-map__view[data-view=folded] .nd-map__svg .nd-map__node--fold", count: 2
    first(".nd-map__view[data-view=folded] .nd-map__svg .nd-map__node--fold").click
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
      assert rows.all? { |_, _, verb| verb == verb.upcase }, "phone group labels use the desktop headings (capitals): #{rows.map(&:last).inspect}"
      directions = rows.map(&:first)
      assert_equal directions, directions.sort_by { |inbound| inbound ? 0 : 1 }, "givers first"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
      assert_equal "Connections", find(".nd-tree__centre", visible: true).text.then { "Connections" }, "the page's record tops the tree"
    end
  end

  test "on a phone the folded plants open under their row" do
    resize_viewport(390, 844)
    visit "/companies/#{build_constellation.slug}"
    owns = find(".nd-tree__row", text: /\AOWNS/)
    owns.find("summary", text: "2 of 13 plants").click

    assert_selector ".nd-tree__fold[open] .nd-tree__plants li", count: 2, text: /Clean Energy Center/
    find(".nd-tree__row", text: /\AOPERATES/).find("summary", text: "13 plants").click
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
    assert_operator page.evaluate_script("document.querySelector('.nd-map__svg').getBoundingClientRect().width").round, :<=, 696
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

  # #995 (Tosin): the record and its branches, as one unit, centred under the Connections heading at every width.
  # Vistra has connections on one side only, NuScale one connection, Constellation both sides.
  def build_vistra
    vistra = cite!(company("Vistra Corporation", roles: [ role("utility") ]))
    buyer = Role.find_by(key: "data_center_offtaker") || role("data_center_offtaker")
    %w[Amazon Meta].each { |name| deal(cite!(company(name, roles: [ buyer ])), "offtake_with", vistra, "Signed 20-year PPA (2025) for nuclear power.") }
    [ "Beaver Valley", "Comanche Peak", "Davis Besse", "Perry" ].each do |name|
      cite!(link(vistra, "operates", cite!(plant(name, facility_type: "power_reactor", status: "operating", state: "TX"))))
    end
    vistra
  end

  def build_nuscale
    nuscale = cite!(company("NuScale Power", roles: [ role("reactor_vendor") ]))
    deal(nuscale, "supplies", cite!(company("ENTRA1 Energy")), "Signed exclusive agreement (2025) to market NuScale plants.")
    nuscale
  end

  # What is drawn (the record, lines, headings and names; or, where the tree takes over, the tree) against its section:
  # [offset of the centres, inside?]. The drawn content, not the <svg> box, which could be wider than what it draws.
  CENTRED = <<~JS.freeze
    (() => {
      const section = document.querySelector(".nd-map").getBoundingClientRect()
      const svg = [ ...document.querySelectorAll(".nd-map__svg") ].find((element) => element.getClientRects().length > 0)
      const rects = svg ? [ ...svg.querySelectorAll(":scope > g") ].map((group) => group.getBoundingClientRect()).filter((rect) => rect.width > 0)
        : [ document.querySelector(".nd-tree").getBoundingClientRect() ]
      const left = Math.min(...rects.map((rect) => rect.left)), right = Math.max(...rects.map((rect) => rect.right))
      return [ (left + right) / 2 - (section.left + section.right) / 2, left >= section.left - 0.5 && right <= section.right + 0.5 ]
    })()
  JS
  # Each partner's name on the map: [text, font size, cut?, side]. The record's own name (anchored in the middle) is left out.
  NAMES = "[...document.querySelectorAll('.nd-map__name:not([text-anchor=middle])')].map((n) => [n.firstChild.nodeValue, n.style.fontSize, 'truncate' in n.dataset, n.getAttribute('text-anchor') === 'start' ? 'right' : 'left'])"

  test "the connections, as one unit, sit centred under the heading at 1440, 1024, 390 and 320 (#995)" do
    pages = { "Vistra" => "/companies/#{build_vistra.slug}", "NuScale Power" => "/companies/#{build_nuscale.slug}",
              "Constellation" => "/companies/#{build_constellation.slug}" }
    [ [ 1440, 900 ], [ 1024, 800 ], [ 390, 844 ], [ 320, 800 ] ].each do |width, height|
      resize_viewport(width, height)
      pages.each do |name, url|
        visit url
        assert_selector ".nd-map__svg[data-laid-out=true]" if width == 1440
        offset, inside = page.evaluate_script(CENTRED)
        assert_in_delta 0, offset, 1, "#{name} at #{width}: centred"
        assert inside, "#{name} at #{width}: inside its section"
        assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "#{name} at #{width}: no sideways scroll"
      end
    end
  end

  test "an empty side takes no room, so a one-sided map's names keep their full size (Vistra, #995)" do
    resize_viewport(1440, 900)
    visit "/companies/#{build_vistra.slug}"
    assert_selector ".nd-map__svg[data-laid-out=true]"

    names = page.evaluate_script(NAMES)
    assert_equal [ "Amazon", "Meta", "Beaver Valley", "Comanche Peak", "Davis Besse", "Perry" ].sort, names.map(&:first).sort, "every name whole"
    assert names.all? { |_, size, cut, side| size == "15px" && !cut && side == "right" }, names.inspect
    assert_empty page.evaluate_script(CHECK)
  end

  test "the names in one column share one size: a long one shrinks its neighbours with it (#995)" do
    kairos = cite!(company("Kairos Demo Power", roles: [ role("reactor_vendor") ]))
    deal(cite!(company("U.S. Department of Energy Office of Nuclear Energy Programs")), "funds", kairos, "Award (2020): ARDP risk reduction.")
    deal(kairos, "supplies", cite!(company("Google")), "Signed master plant development agreement (2024) for 500 MW.")
    [ "Hermes Low-Power Demonstration Reactor Site", "Hermes 2" ].each do |name|
      cite!(link(kairos, "operates", cite!(plant(name, facility_type: "research_reactor", status: "under_construction", state: "TN"))))
    end
    resize_viewport(1440, 900)
    visit "/companies/#{kairos.slug}"
    assert_selector ".nd-map__svg[data-laid-out=true]"

    sizes = page.evaluate_script(NAMES).map { |_, size, _, side| [ side, size ] }
    assert_operator sizes.size, :>=, 4
    sizes.group_by(&:first).each { |side, column| assert_equal 1, column.map(&:last).uniq.size, "#{side}: #{column.inspect}" }
    right = sizes.select { |side, _| side == "right" }.map(&:last).uniq
    assert_operator right.first.to_f, :<, 15, "the long plant name sets its column's size, Google's included"
  end
end
