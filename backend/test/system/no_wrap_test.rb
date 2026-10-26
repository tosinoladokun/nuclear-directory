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
