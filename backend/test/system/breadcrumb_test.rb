require "application_system_test_case"
require_relative "../support/directory_builders"

# The trail on company and plant pages (#708, #700): Nuclear Directory > category on one line at every width; the category
# shortens (full text in title) before anything wraps; "Nuclear Directory" never does.
class BreadcrumbTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    @company = cite!(company("The Very Long Named Nuclear Energy Holdings and Services International Corporation", roles: [ role("utility") ]))
  end

  test "one line at every width, Nuclear Directory never cut, the category in title" do
    [ 320, 360, 390, 768, 1024, 1440 ].each do |width|
      resize_viewport(width, 800)
      visit company_path(slug: @company.slug)
      rows = page.evaluate_script("[...document.querySelectorAll('.nd-breadcrumb li')].map((li) => { const el = li.firstElementChild; return [el.textContent.trim(), Math.round(li.getBoundingClientRect().height), el.scrollWidth > el.clientWidth + 1, el.getAttribute('title')] })")
      assert_equal [ "Nuclear Directory", "Power plant owners and operators" ], rows.map(&:first), "at #{width}"
      assert rows.all? { |_, height, _, _| height <= 24 }, "one line at #{width}: #{rows.inspect}"
      assert_equal false, rows.first[2], "Nuclear Directory is never cut at #{width}"
      assert rows.all? { |text, _, _, title| title == text }, "every crumb has its full text in title at #{width}"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "no sideways scroll at #{width}"
    end
  end

  test "on a touch screen the links are 44px tall, a long category still ends in an ellipsis, and the chevron stays centred" do
    resize_viewport(320, 800)
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: true, maxTouchPoints: 5)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "any-pointer", value: "coarse" }, { name: "pointer", value: "coarse" } ])
    visit company_path(slug: @company.slug)
    rows = page.evaluate_script("[...document.querySelectorAll('.nd-breadcrumb li')].map((li) => { const a = li.firstElementChild, box = li.getBoundingClientRect(), text = a.getBoundingClientRect(); return [Math.round(a.getBoundingClientRect().height), getComputedStyle(a).textOverflow, getComputedStyle(a).display, Math.abs((box.top + box.height / 2) - (text.top + text.height / 2)) < 2] })")
    assert rows.all? { |height, _, _, _| height >= 44 }, "44px tall: #{rows.inspect}"
    assert rows.all? { |_, overflow, display, _| overflow == "ellipsis" && display != "inline-flex" }, "the link stays a block that can ellipsize: #{rows.inspect}"
    assert rows.all? { |_, _, _, centred| centred }, "each li's contents are centred, so the chevron sits level with the text"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  ensure
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    page.driver.browser.execute_cdp("Emulation.setTouchEmulationEnabled", enabled: false)
  end
end
