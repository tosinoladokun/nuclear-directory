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

  test "the footer's one-line text and the crawler page's Glance stay one line each from 760px up and on a phone (Design, #660)" do
    [ [ 760, 900 ], [ 1024, 800 ], [ 1440, 800 ], [ 390, 844 ] ].each do |width, height|
      resize_viewport(width, height)
      visit bot_path
      assert_empty page.evaluate_script(AUDIT), "no-wrap audit at #{width}"
      assert_equal [ "Pace, per site", "Visits per page", "Rules", "If blocked" ], all(".nd-glance dt").map(&:text)
      heights = page.evaluate_script("[...document.querySelectorAll('.nd-glance__fact')].map((f) => Math.round(f.getBoundingClientRect().height))")
      assert heights.all? { |h| h <= 52 }, "one value and one label each, no third line at #{width}: #{heights.inspect}"
    end
    resize_viewport(1440, 800)
    visit bot_path
    assert_equal "29px", page.evaluate_script("getComputedStyle(document.querySelector('.nd-info__summary')).lineHeight")
    assert_equal page.evaluate_script("getComputedStyle(document.querySelector('h1')).color"), page.evaluate_script("getComputedStyle(document.querySelector('.nd-info__summary')).color"), "the summary is in ink, the page's main point"
  end

  test "on a touch phone the footer links are 44px tall and their tap areas never overlap (the credit moved to About, #660)" do
    resize_viewport(390, 844)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "any-pointer", value: "coarse" }, { name: "pointer", value: "coarse" } ])
    visit root_path
    heights = page.evaluate_script("[...document.querySelectorAll('.nd-footer__links a')].map((a) => Math.round(a.getBoundingClientRect().height))")
    assert_operator heights.size, :>=, 5
    assert heights.all? { |height| height >= 43 }, "every footer link is a 44px tap target: #{heights.inspect}"
    apart = page.evaluate_script("(() => { const rects = [...document.querySelectorAll('.nd-footer__links a')].map((a) => a.getBoundingClientRect()); return rects.every((a, i) => rects.every((b, j) => i === j || a.right <= b.left + 1 || b.right <= a.left + 1 || a.bottom <= b.top + 1 || b.bottom <= a.top + 1)) })()")
    assert apart, "tap areas of the footer links never overlap"
    assert_no_selector ".nd-footer__credit"
    assert_empty page.evaluate_script(AUDIT)
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
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
