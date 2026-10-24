require "application_system_test_case"
require_relative "../support/directory_builders"

# Tosin's rule (DESIGN.md, #365): text in a box, chip, button or list row
# never wraps or hyphenates, and a source number never starts a line on its
# own. Checked with the live site's problem cases at phone widths, since
# iOS renders a little wider than Chrome.
class NoWrapTest < ApplicationSystemTestCase
  include DirectoryBuilders

  # Capybara returns the script's value, so the file's comment lines go.
  AUDIT = File.readlines(File.expand_path("../support/no_wrap_audit.js", __dir__)).reject { |line| line.start_with?("//") }.join

  setup do
    services = role("reactor_services")
    utility = role("utility")
    @parent = cite!(company("Bernhard Capital Partners Management"))
    @allied = cite!(company("Allied Power Services Holdings", roles: [ services ], website: "https://www.alliedpowerservices.com",
      city: "Baton Rouge", state: "LA", description: "Company that provides maintenance, modification and staffing services to power plants, including nuclear plants."))
    cite!(link(@allied, "subsidiary_of", @parent))
    @plant = cite!(plant("Calvert Cliffs Nuclear Power Plant", facility_type: "power_reactor", status: "operating", city: "Lusby", state: "MD"))
    cite!(plant("Calvert Cliffs Unit 1", parent: @plant, status: "operating", reactor_type: "PWR", capacity_mw: 884))
    cite!(plant("Calvert Cliffs Unit 2", parent: @plant, status: "operating", reactor_type: "PWR", capacity_mw: 862))
    [ "Constellation Energy Generation", "Oglethorpe Power Corporation", "Southern Nuclear Operating Co., Inc.", "Municipal Electric Authority of Georgia" ]
      .each { |name| cite!(link(cite!(company(name, roles: [ utility ])), "owns", @plant)) }
    cite!(company("Dual Role Reactor Designer and Project Developer Holdings International", roles: [ role("reactor_vendor"), role("project_developer") ],
      description: "Company that designs a small modular reactor and develops the plants that will use it, in several states."))
    cite!(company("Metropolis Works Uranium Conversion Facility Operator LLC", roles: [ role("fuel") ],
      description: "Company that supplies uranium hexafluoride conversion services to nuclear power plants worldwide."))
  end

  PAGES = ->(test) { [ "/", "/companies", "/companies?category=reactor-developers", "/companies?category=reactor-developers&role=project_developer", "/companies?category=services", "/companies?category=plants",
    "/companies/#{test.instance_variable_get(:@allied).slug}", "/plants/#{test.instance_variable_get(:@plant).slug}" ] }

  test "a long value with two-digit source numbers shrinks and never pushes past its column" do
    resize_viewport(360, 800)
    visit "/companies/#{@allied.slug}"
    # The Headquarters row, made as long as a fitted value gets, with sources 10 and 11.
    fits = page.evaluate_script(<<~JS)
      (() => {
        const line = [...document.querySelectorAll(".nd-overview__line--fit")].find((l) => l.querySelector(".nd-src"))
        const val = line.querySelector(".nd-overview__val")
        val.textContent = "Baton Rouge Metropolitan Area, LA"
        line.style.setProperty("--chars", 33)
        const cites = line.querySelector(".nd-overview__cites")
        cites.querySelectorAll(".nd-src sup").forEach((sup, i) => sup.textContent = String(10 + i))
        cites.append(cites.querySelector(".nd-src").cloneNode(true))
        const dd = line.closest("dd")
        return [dd.scrollWidth <= dd.clientWidth, line.getBoundingClientRect().right <= dd.getBoundingClientRect().right + 1]
      })()
    JS
    assert_equal [ true, true ], fits
  end

  test "a long single value with a comma fits one line, sized by its real length, with its full text in title" do
    @allied.update!(hq_city: "Baton Rouge Metropolitan Area", legal_name: "Allied Power Services Holdings Corporation of Louisiana, LLC")
    resize_viewport(360, 800)
    visit "/companies/#{@allied.slug}"

    assert_selector ".nd-overview__line--fit .nd-overview__val[title='Baton Rouge Metropolitan Area, LA']"
    legal = find(".nd-overview__line--fit .nd-overview__val[title^='Allied Power Services Holdings Corporation']")
    assert_equal @allied.legal_name.length.to_s, legal.find(:xpath, "..")[:style][/--chars: (\d+)/, 1], "sized by its real length, not 32"
    assert_empty page.evaluate_script(AUDIT)
  end

  test "a fitted value carries its full text in title, and a focused link in it shows its ring" do
    resize_viewport(360, 800)
    visit "/companies/#{@allied.slug}"
    assert_selector ".nd-overview__line--fit .nd-overview__val[title='Baton Rouge, LA']"
    page.execute_script("document.querySelector('.nd-overview__line--fit .nd-overview__val a').focus()")
    page.send_keys(:tab, [ :shift, :tab ]) # keyboard focus, so :focus-visible applies
    ring = page.evaluate_script("(() => { const v = document.activeElement.closest('.nd-overview__val'); return v ? getComputedStyle(v).outlineStyle : 'none' })()")
    assert_equal "solid", ring
  end

  test "the Type chips sit under their label across the panel, one line each, at 390 and 1440" do
    [ [ 390, 844 ], [ 1440, 900 ] ].each do |width, height|
      resize_viewport(width, height)
      visit "/companies/#{@allied.slug}"
      chips = page.evaluate_script(<<~JS)
        [...document.querySelectorAll(".nd-overview .nd-bucketchip")].map((chip) => {
          const dd = chip.closest("dd")
          return [Math.round(chip.getBoundingClientRect().height), dd.scrollWidth <= dd.clientWidth, getComputedStyle(dd).gridColumnStart]
        })
      JS
      assert_not_empty chips
      chips.each do |height, fits, column|
        assert_operator height, :<=, 26, "a chip is one line at #{width}"
        assert fits, "the chip's row doesn't overflow at #{width}"
        assert_equal "1", column, "the chips start under the label at #{width}"
      end
      assert_equal [ "Services and engineering" ], page.evaluate_script("[...document.querySelectorAll('.nd-bucketchip__full')].filter((el) => el.offsetParent).map((el) => el.textContent)"),
        "the full name fits at #{width}"
    end
  end

  test "the hung Type pill stays inside the panel, and its icon sits on the label's edge, at 390 and 1440" do
    [ [ 390, 844 ], [ 1440, 900 ] ].each do |width, height|
      resize_viewport(width, height)
      visit "/companies/#{@allied.slug}"
      edges = page.evaluate_script(<<~JS)
        (() => {
          const panel = document.querySelector(".nd-overview").getBoundingClientRect(), chip = document.querySelector(".nd-overview .nd-bucketchip")
          const box = chip.getBoundingClientRect(), label = chip.closest("dd").previousElementSibling.getBoundingClientRect()
          return [box.left >= panel.left + 1, box.right <= panel.right - 1, Math.abs(box.left + parseFloat(getComputedStyle(chip).paddingLeft) - label.left) <= 1]
        })()
      JS
      assert_equal [ true, true, true ], edges, "at #{width}: inside the panel, icon on the label's edge"
      assert_empty page.evaluate_script(AUDIT), "at #{width}"
    end
  end

  test "two or more other names go under their label at 1440 and 390, each on one line with its full text in title" do
    [ "Allied Power", "Allied Power Services, a Bernhard Capital Partners company", "APS Holdings" ].each { |name| @allied.aliases.create!(alias: name) }
    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_viewport(width, height)
      visit "/companies/#{@allied.slug}"
      row = page.evaluate_script(<<~JS)
        (() => {
          const dt = [...document.querySelectorAll(".nd-overview dt")].find((el) => el.textContent.trim() === "Also known as"), dd = dt.nextElementSibling
          const names = [...dd.querySelectorAll(".nd-overview__name")]
          return [dt.classList.contains("nd-overview__stack"), names.length, names.every((n) => n.title === n.textContent && "truncate" in n.dataset), dd.scrollWidth <= dd.clientWidth]
        })()
      JS
      assert_equal [ true, 3, true, true ], row, "at #{width}: stacked under the label, three names, each with its full text in title"
      assert_empty page.evaluate_script(AUDIT), "at #{width}"
    end
  end

  test "a company with many roles lists them under the label, none overflowing, at 360 and 390" do
    ge = cite!(company("GE Vernova Hitachi Nuclear Energy", roles: %w[reactor_vendor fuel components reactor_services waste_decommissioning].map { |key| Role.find_by(key:) || role(key) }))
    [ [ 360, 800 ], [ 390, 844 ] ].each do |width, height|
      resize_viewport(width, height)
      visit "/companies/#{ge.slug}"
      row = page.evaluate_script(<<~JS)
        (() => {
          const dt = [...document.querySelectorAll(".nd-overview dt")].find((el) => /^Roles?$/.test(el.textContent.trim())), dd = dt.nextElementSibling
          return [dt.textContent.trim(), dt.classList.contains("nd-overview__stack"), dd.querySelectorAll(".nd-overview__name").length > 1, dd.scrollWidth <= dd.clientWidth]
        })()
      JS
      assert_equal [ "Roles", true, true, true ], row, "at #{width}"
      assert_empty page.evaluate_script(AUDIT), "at #{width}"
    end
  end

  test "the key-facts edge check sees an inset value, stacked or beside its label" do
    [ [ 390, 844 ], [ 1440, 900 ] ].each do |width, height|
      resize_viewport(width, height)
      visit "/companies/#{@allied.slug}"
      assert_empty page.evaluate_script(AUDIT), "at #{width}: clean before the inset"
      page.execute_script("document.querySelector('.nd-overview .nd-overview__val:not(:has(ul))').style.paddingLeft = '6px'")
      found = page.evaluate_script(AUDIT)
      assert found.any? { |problem| problem.include?("edge") }, "at #{width}: a value inset by padding is reported, got #{found.inspect}"
    end
  end

  test "on a touch phone the footer credit keeps the space before its link and the link is 44px tall" do
    resize_viewport(390, 844)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "any-pointer", value: "coarse" }, { name: "pointer", value: "coarse" } ])
    visit root_path
    credit = page.evaluate_script("(() => { const p = document.querySelector('.nd-footer__credit'); return [p.innerText, Math.round(p.querySelector('a').getBoundingClientRect().height), matchMedia('(pointer: coarse)').matches] })()")
    assert_equal [ "Hosting supported by Render.", true ], [ credit[0], credit[2] ]
    assert_operator credit[1], :>=, 43, "the Render link is a 44px tap target"
    apart = page.evaluate_script("(() => { const credit = document.querySelector('.nd-footer__credit a').getBoundingClientRect(); return [...document.querySelectorAll('.nd-footer__links a')].every((a) => { const r = a.getBoundingClientRect(); return r.bottom <= credit.top + 0.5 || r.top >= credit.bottom - 0.5 || r.right <= credit.left || r.left >= credit.right }) })()")
    assert apart, "tap areas of the footer links and the credit never overlap"
    assert_empty page.evaluate_script(AUDIT)
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end

  test "a list of owners goes under its label at 1440, its last owner whole beside its numbers" do
    resize_viewport(1440, 900)
    visit "/plants/#{@plant.slug}"

    row = page.evaluate_script(<<~JS)
      (() => {
        const keep = document.querySelector(".nd-overview__keep")
        const dd = keep.closest("dd"), dt = dd.previousElementSibling, last = keep.querySelector(".nd-overview__last")
        return [getComputedStyle(dt).gridColumnStart, getComputedStyle(dd).gridColumnStart, last.textContent,
          last.scrollWidth <= last.clientWidth, parseFloat(getComputedStyle(last).fontSize) >= 13]
      })()
    JS
    assert_equal [ "1", "1", "Southern Nuclear Operating Co., Inc.", true, true ], row, "stacked at the panel's width, the last owner uncut"
    assert_empty page.evaluate_script(AUDIT)
  end

  test "a long owner before the last ends in an ellipsis inside the column, with its full name in title" do
    long = "Constellation Energy Generation Company of Illinois, Maryland, New York and Pennsylvania, LLC"
    Organization.find_by!(name: "Constellation Energy Generation").update!(name: long)
    [ [ 1440, 900 ], [ 390, 844 ] ].each do |width, height|
      resize_viewport(width, height)
      visit "/plants/#{@plant.slug}"

      fits = page.evaluate_script(<<~JS)
        (() => {
          const keep = document.querySelector(".nd-overview__keep")
          const dd = keep.closest("dd"), first = dd.querySelector(".nd-overview__val a")
          return [dd.scrollWidth <= dd.clientWidth, first.getBoundingClientRect().right <= dd.getBoundingClientRect().right + 1, first.title, "truncate" in first.dataset]
        })()
      JS
      assert_equal [ true, true, long, true ], fits, "at #{width}"
      assert_empty page.evaluate_script(AUDIT), "at #{width}"
    end
  end

  test "a long last owner and its numbers stay inside the key facts column at 1440" do
    # Last in the list, by name.
    Organization.find_by!(name: "Southern Nuclear Operating Co., Inc.").update!(name: "Southern Nuclear Operating Company of Alabama, Georgia and Mississippi, Inc.")
    resize_viewport(1440, 900)
    visit "/plants/#{@plant.slug}"

    keep = page.evaluate_script(<<~JS)
      (() => {
        const keep = document.querySelector(".nd-overview__keep")
        const dd = keep.closest("dd"), last = keep.querySelector(".nd-overview__last"), cites = keep.querySelector(".nd-overview__cites")
        const box = dd.getBoundingClientRect()
        return [dd.scrollWidth <= dd.clientWidth, keep.getBoundingClientRect().right <= box.right + 1,
          cites.getBoundingClientRect().right <= box.right + 1, cites.getBoundingClientRect().width > 0, last.title]
      })()
    JS
    assert_equal [ true, true, true, true ], keep.first(4), "the last owner and its numbers fit the column"
    assert_match(/Southern Nuclear Operating Company of Alabama/, keep.last)
    assert_empty page.evaluate_script(AUDIT)
  end

  [ [ 360, 800 ], [ 390, 844 ] ].each do |width, height|
    test "nothing wraps and no source number stands alone at #{width}" do
      resize_viewport(width, height)
      problems = PAGES.call(self).flat_map do |path|
        visit path
        page.evaluate_script(AUDIT).map { |problem| "#{path}: #{problem}" }
      end

      assert_empty problems, problems.join("\n")
    end
  end
end
