require "application_system_test_case"
require_relative "../support/directory_builders"

# The trail on company and plant pages (#708): one line at every width; the page's own name shortens first (full text in
# title), then the category; "Nuclear Directory" never does.
class BreadcrumbTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    @company = cite!(company("The Very Long Named Nuclear Energy Holdings and Services International Corporation", roles: [ role("utility") ]))
  end

  test "one line, the name shortens first, at phone, tablet and desktop widths" do
    [ 320, 360, 390, 768, 1024, 1440 ].each do |width|
      resize_viewport(width, 800)
      visit company_path(slug: @company.slug)
      rows = page.evaluate_script("[...document.querySelectorAll('.nd-breadcrumb li')].map((li) => { const el = li.firstElementChild; return [el.textContent.trim(), Math.round(li.getBoundingClientRect().height), el.scrollWidth > el.clientWidth + 1, el.getAttribute('title')] })")
      assert_equal [ "Nuclear Directory", "Power plant owners and operators", @company.name ], rows.map(&:first), "at #{width}"
      assert rows.all? { |_, height, _, _| height <= 24 }, "one line at #{width}: #{rows.inspect}"
      assert_equal false, rows.first[2], "Nuclear Directory is never cut at #{width}"
      assert rows.all? { |text, _, _, title| title == text }, "every crumb has its full text in title at #{width}"
      cut = rows.map { |_, _, shortened, _| shortened }
      assert_not cut[1] && !cut[2], "the category only shortens when the name does too at #{width}: #{cut.inspect}"
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"), "no sideways scroll at #{width}"
    end
  end
end
