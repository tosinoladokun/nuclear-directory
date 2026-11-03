require "application_system_test_case"
require_relative "../support/directory_builders"

# Home card titles are shown in full and on one line (Tosin, 31 Oct): no ellipsis, no short name, no wrapping, one shared size.
class HomeCardTitlesTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    roles = %w[reactor_vendor fuel components waste_decommissioning utility data_center_offtaker reactor_services venture_capital government_agency].to_h { |key| [ key, role(key) ] }
    roles.each { |key, bucket_role| cite!(company("#{key.humanize} Company", roles: [ bucket_role ])) }
    # Two-digit counts, as on production: the count must never take the title's room.
    11.times { |n| cite!(company("Extra Utility #{n}", roles: [ roles["utility"] ])) }
    cite!(plant("Some Station", facility_type: "power_reactor", status: "operating"))
  end

  FULL = Category.all.map(&:name).freeze

  test "every title reads in full on ONE line, none cut short, never smaller than the rows under it, at every width" do
    [ 320, 360, 374, 375, 390, 640, 700, 768, 900, 1024, 1100, 1280, 1440 ].each do |width|
      resize_viewport(width, 900)
      visit root_path
      sleep 0.2
      shown = page.evaluate_script("[...document.querySelectorAll('.nd-catcard__name')].filter((n) => n.getClientRects().length).map((n) => { const row = n.closest('.nd-catcard').querySelector('.nd-catcard__rowname'); return [n.textContent.trim(), n.scrollWidth <= n.clientWidth + 1, Math.round(n.getBoundingClientRect().height / parseFloat(getComputedStyle(n).lineHeight)), parseFloat(getComputedStyle(n).fontSize), row ? parseFloat(getComputedStyle(row).fontSize) : 0] })")
      assert_equal FULL.sort, shown.map(&:first).sort, "at #{width}"
      assert shown.all? { |_, fits, _, _, _| fits }, "none cut short at #{width}: #{shown.reject { |_, fits, _, _, _| fits }.inspect}"
      assert shown.all? { |_, _, lines, _, _| lines == 1 }, "one line each at #{width}: #{shown.inspect}"
      assert shown.all? { |_, _, _, size, row| size >= row || width < 375 }, "a title is never smaller than its rows (13px floor only below 375px) at #{width}: #{shown.reject { |_, _, _, size, row| size >= row }.inspect}"
      assert_equal 1, shown.map { |item| item[3] }.uniq.size, "one title size at #{width}: #{shown.map { |item| item[3] }.uniq.inspect}"
    end
  end

  test "the home grid is two columns from 640px up, and the count sits beside the title" do
    resize_viewport(1440, 900)
    visit root_path
    columns = page.evaluate_script("getComputedStyle(document.querySelector('.nd-catgrid')).gridTemplateColumns.split(' ').length")
    assert_equal 2, columns
    beside = page.evaluate_script("(() => { const h = document.querySelector('.nd-catcard__head--link'); const n = h.querySelector('.nd-catcard__name').getBoundingClientRect(); const c = h.querySelector('.nd-catcard__count').getBoundingClientRect(); return Math.abs((n.top + n.height / 2) - (c.top + c.height / 2)) < 12 })()")
    assert beside, "the count is on the title's line"
  end
end
