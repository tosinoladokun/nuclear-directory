require "application_system_test_case"
require_relative "../support/directory_builders"

# The home page's category cards (#362), against the spec's acceptance tests.
class HomeCardsTest < ApplicationSystemTestCase
  include DirectoryBuilders

  AUDIT = File.readlines(File.expand_path("../support/no_wrap_audit.js", __dir__)).reject { |line| line.start_with?("//") }.join

  # Every bucket full, with long names, as on production.
  setup do
    %w[reactor_vendor fuel components waste_decommissioning utility data_center_offtaker reactor_services venture_capital government_agency]
      .each_with_index do |key, index|
        bucket_role = role(key)
        4.times { |n| cite!(company("#{key.humanize} Company Number #{n} Holdings International #{index}", roles: [ bucket_role ])) }
      end
    4.times { |n| cite!(plant("Long Named Generating Station Number #{n}", facility_type: "power_reactor", status: "operating")) }
  end

  def cards = page.evaluate_script("[...document.querySelectorAll('section.nd-catcard')].map((c) => [c.dataset.key, c.querySelectorAll('a.nd-catcard__row').length])")

  test "the suggested searches are one line at every width: the ones that don't fit are hidden, never wrapped or scrolled" do
    [ [ 360, 780 ], [ 390, 844 ], [ 640, 900 ], [ 700, 900 ], [ 1440, 900 ] ].each do |width, height|
      resize_viewport(width, height)
      visit root_path

      row = page.evaluate_script(<<~JS)
        (() => {
          const row = document.querySelector(".nd-home .nd-suggs"), all = [...row.querySelectorAll(".nd-sugg")]
          const shown = all.filter((pill) => !pill.hidden), tops = new Set(shown.map((pill) => Math.round(pill.getBoundingClientRect().top)))
          const rowBox = row.getBoundingClientRect()
          return [all.length, shown.length >= 2, tops.size, Math.max(...shown.map((pill) => Math.round(pill.getBoundingClientRect().height))),
            parseFloat(getComputedStyle(shown[0]).fontSize) >= 13, shown.every((pill) => pill.getBoundingClientRect().right <= rowBox.right + 1 && pill.getBoundingClientRect().left >= rowBox.left - 1),
            row.scrollWidth <= row.clientWidth, document.documentElement.scrollWidth <= innerWidth]
        })()
      JS
      assert_equal [ HomeSuggestions::SHOWN, true, 1, 28, true, true, true, true ], row, "at #{width}: at least two pills, one line, 28px, inside the row, no scroll anywhere"
      assert_empty page.evaluate_script(AUDIT), "at #{width}"
    end
  end

  test "a narrow phone shows fewer suggestions than a wide screen, and the hidden ones are out of the tab order" do
    resize_viewport(360, 780)
    visit root_path
    narrow = page.evaluate_script("[...document.querySelectorAll('.nd-home .nd-sugg')].filter((pill) => !pill.hidden).length")
    resize_viewport(1440, 900)
    wide = page.evaluate_script("[...document.querySelectorAll('.nd-home .nd-sugg')].filter((pill) => !pill.hidden).length")
    assert_equal HomeSuggestions::SHOWN, wide, "all of them fit on a wide screen"
    assert_operator narrow, :<, wide, "fewer fit at 360"
    resize_viewport(360, 780)
    assert_equal narrow, page.evaluate_script("[...document.querySelectorAll('.nd-home .nd-sugg')].filter((pill) => !pill.hidden).length"), "the same on the way back"
    assert page.evaluate_script("[...document.querySelectorAll('.nd-home .nd-sugg[hidden]')].every((pill) => pill.offsetParent === null)"), "hidden pills take no space and can't be tabbed to"
  end

  test "on a touch screen the suggestions stay 28px tall, with a 44px tap area" do
    resize_viewport(390, 844)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "any-pointer", value: "coarse" } ])
    visit root_path

    sizes = page.evaluate_script(<<~JS)
      (() => {
        const pill = document.querySelector(".nd-home .nd-sugg"), tap = getComputedStyle(pill, "::after"), box = pill.getBoundingClientRect()
        const x = box.left + box.width / 2
        // A tap 6px above or below the pill still reaches it: the row doesn't clip its tap area.
        const reaches = (y) => document.elementFromPoint(x, y)?.closest(".nd-sugg") === pill
        return [matchMedia("(any-pointer: coarse)").matches, Math.round(box.height), tap.height, reaches(box.top - 6), reaches(box.bottom + 6)]
      })()
    JS
    assert_equal [ true, 28, "44px", true, true ], sizes
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "at 360 the search placeholder is a shorter one that fits; at 390 the full one" do
    { 360 => "Search companies and plants", 390 => "Search a company, plant or site" }.each do |width, placeholder|
      resize_viewport(width, 800)
      visit root_path
      input = find(".nd-home input[type=search]")
      assert_equal placeholder, input[:placeholder], "at #{width}"
      fits = page.evaluate_script(<<~JS)
        (() => {
          const input = document.querySelector(".nd-home input[type=search]"), style = getComputedStyle(input)
          const canvas = document.createElement("canvas").getContext("2d")
          canvas.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
          return [parseFloat(style.fontSize), canvas.measureText(input.placeholder).width <= input.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight)]
        })()
      JS
      assert_equal [ 16.0, true ], fits, "16px and uncut at #{width}"
    end
  end

  test "back on the page after a narrow visit, widening restores the full placeholder" do
    resize_viewport(360, 800)
    visit root_path
    assert_equal "Search companies and plants", find(".nd-home input[type=search]")[:placeholder]

    # As a Turbo snapshot restore does: the same markup, short placeholder and all, connected afresh.
    page.execute_script(<<~JS)
      const box = document.querySelector(".nd-home .nd-searchbox")
      box.replaceWith(box.cloneNode(true))
    JS
    resize_viewport(390, 844)
    assert_equal "Search a company, plant or site", find(".nd-home input[type=search]")[:placeholder]
  end

  test "just past the phone breakpoint (640 to 699) every card title still fits on one line" do
    [ 640, 670, 699 ].each do |width|
      resize_viewport(width, 900)
      visit root_path
      assert_empty page.evaluate_script(AUDIT), "at #{width}"
    end
  end

  test "on a phone the whole card header is the button, edge to edge" do
    resize_viewport(390, 844)
    visit root_path
    edges = page.evaluate_script(<<~JS)
      (() => {
        const head = document.querySelector(".nd-catcard__head--toggle"), button = head.querySelector(".nd-catcard__toggle")
        const h = head.getBoundingClientRect(), b = button.getBoundingClientRect()
        return [Math.round(b.left - h.left), Math.round(h.right - b.right)]
      })()
    JS
    assert_equal [ 0, 0 ], edges, "no untappable strip at either edge"
  end

  test "a category title is never cut short: it fits, and it isn't excused from being cut" do
    visit root_path
    titles = page.evaluate_script(<<~JS)
      [...document.querySelectorAll(".nd-catcard__name")].map((name) => [name.textContent.trim(), name.hasAttribute("data-truncate"), name.scrollWidth <= name.clientWidth + 1])
    JS
    assert_not_empty titles
    titles.each do |text, excused, fits|
      assert_not excused, "#{text} is marked as allowed to be cut short"
      assert fits, "#{text} is cut short"
    end
  end

  test "on a phone the focus ring on a card row is drawn inside the row, so the card can't cut it" do
    resize_viewport(390, 844)
    visit root_path

    page.execute_script(<<~JS)
      const row = [...document.querySelectorAll(".nd-catstack a.nd-catcard__row")].find((r) => r.getBoundingClientRect().height > 0)
      row.focus()
    JS
    page.send_keys(:tab, [ :shift, :tab ]) # keyboard focus, so :focus-visible applies
    style, offset, inset = page.evaluate_script(<<~JS)
      (() => {
        const row = document.activeElement, box = row.getBoundingClientRect()
        const inner = row.closest(".nd-catcard__inner").getBoundingClientRect()
        return [getComputedStyle(row).outlineStyle, parseFloat(getComputedStyle(row).outlineOffset), Math.round(box.left - inner.left)]
      })()
    JS
    assert_equal "solid", style, "the row shows a focus ring"
    assert_operator offset, :<=, 0, "the ring is drawn inside the row"
    assert_equal 0, inset, "the row runs edge to edge, so only an inside ring survives"
  end

  test "on a phone the focus ring on a suggestion pill is drawn inside the pill, so the row's clip can't cut it" do
    resize_viewport(390, 844)
    visit root_path

    page.execute_script("document.querySelector('.nd-home .nd-sugg').focus()")
    page.send_keys(:tab, [ :shift, :tab ]) # keyboard focus, so :focus-visible applies
    style, offset = page.evaluate_script(<<~JS)
      (() => {
        const pill = document.activeElement
        return [getComputedStyle(pill).outlineStyle, parseFloat(getComputedStyle(pill).outlineOffset)]
      })()
    JS
    assert_equal "solid", style, "the pill shows a focus ring"
    assert_operator offset, :<=, 0, "the ring is drawn inside the pill"
  end

  test "the /design example cards are as wide as on the home page, and nothing in them is cut" do
    visit "/design"
    widths = page.evaluate_script("[...document.querySelectorAll('.nd-catgrid--example .nd-catcard')].map((card) => Math.round(card.getBoundingClientRect().width))")
    assert widths.all? { |width| width >= 190 }, widths.inspect
    problems = page.evaluate_script(AUDIT).grep(/nd-catcard/)
    assert_empty problems, problems.join("\n")
  end

  [ [ 1440, 900 ], [ 1280, 800 ] ].each do |width, height|
    test "at #{width}x#{height} the cards are a compact 3-column grid, never wider than 960px, one line everywhere" do
      resize_viewport(width, height)
      visit root_path

      grid = page.evaluate_script("(() => { const g = document.querySelector('.nd-home .nd-catgrid'), box = g.getBoundingClientRect(), page = document.documentElement; return [Math.round(box.width), getComputedStyle(g).gridTemplateColumns.split(' ').length, Math.round(box.left + box.width / 2), page.clientWidth / 2] })()")
      assert_operator grid[0], :<=, 960, "the grid is compact, not screen-wide"
      assert_equal 3, grid[1], "3 columns"
      assert_in_delta grid[3], grid[2], 1, "centred"
      gaps = page.evaluate_script("(() => { const c = [...document.querySelectorAll('.nd-home .nd-catcard')]; return [Math.round(c[3].getBoundingClientRect().top - c[0].getBoundingClientRect().bottom), Math.round(c[1].getBoundingClientRect().left - c[0].getBoundingClientRect().right)] })()")
      assert_equal 24, gaps[0], "24px between rows of cards"
      assert_operator gaps[1], :<=, 14, "the column gap is unchanged"
      assert_equal 10, cards.size
      assert_equal "plants", cards.last.first, "Plants and sites is the last card"
      assert(cards.all? { |_, rows| rows <= 3 })
      assert_empty page.evaluate_script(AUDIT)
      assert page.evaluate_script("[...document.querySelectorAll('.nd-catcard__chev')].every((c) => c.offsetParent)"), "every row shows its › at rest"
    end
  end

  test "on a phone: no sideways scroll, 44px links, sticky headers, cards that collapse and stay collapsed" do
    resize_viewport(390, 844)
    visit root_path

    assert_empty page.evaluate_script(AUDIT)
    short = page.evaluate_script("[...document.querySelectorAll('.nd-catstack a, .nd-catstack button')].filter((el) => el.offsetParent && el.getBoundingClientRect().height < 44).map((el) => el.textContent.trim())")
    assert_empty short, "links under 44px tall"
    assert_equal "plants", cards.last.first
    assert_equal 0, page.evaluate_script("document.querySelectorAll('.nd-catstack .nd-catcard__count').length - document.querySelectorAll('.nd-catcard__head--link .nd-catcard__count').length"), "no counts in phone headers"

    # Scroll into the second card: its header sits at the top.
    top = page.evaluate_script("(() => { const card = document.querySelectorAll('section.nd-catcard')[1]; window.scrollTo(0, card.getBoundingClientRect().top + scrollY + 60); return Math.round(card.querySelector('.nd-catcard__head--toggle').getBoundingClientRect().top) })()")
    assert_equal 0, top, "the header sticks at the top while its rows scroll under it"

    toggle = find("section[data-key=fuel] .nd-catcard__toggle")
    assert_equal "true", toggle["aria-expanded"]
    assert_equal "Fuel and Materials, 4 companies", toggle["aria-label"], "the count is in the button's name on phones"
    toggle.click
    assert_equal "false", toggle["aria-expanded"]
    assert_no_selector "section[data-key=fuel] a.nd-catcard__row", visible: true

    visit root_path
    assert_equal "false", find("section[data-key=fuel] .nd-catcard__toggle")["aria-expanded"], "the choice is remembered"
    click_on "Collapse all"
    assert_equal [ "false" ], all(".nd-catcard__toggle").map { |t| t["aria-expanded"] }.uniq, "every card closes"
    click_on "Expand all"
    assert_equal [ "true" ], all(".nd-catcard__toggle").map { |t| t["aria-expanded"] }.uniq, "every card opens"
    assert_button "Collapse all"
  end
end
