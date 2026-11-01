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

  FULL = [ "Reactor Developers", "Fuel and Materials", "Components and Parts", "Waste and Decommissioning", "Power Plant Owners and Operators",
           "Power Buyers", "Services and Engineering", "Investors", "Government and Research", "Plants and Sites" ].freeze

  test "every title reads in full on ONE line, none cut short, all ten at one shared size, at every width" do
    [ 320, 360, 390, 640, 700, 768, 900, 1024, 1100, 1280, 1440 ].each do |width|
      resize_viewport(width, 900)
      visit root_path
      sleep 0.2
      shown = page.evaluate_script("[...document.querySelectorAll('.nd-catcard__name')].filter((n) => n.getClientRects().length).map((n) => [n.textContent.trim(), n.scrollWidth <= n.clientWidth + 1, Math.round(n.getBoundingClientRect().height / parseFloat(getComputedStyle(n).lineHeight)), getComputedStyle(n).fontSize])")
      assert_equal FULL.sort, shown.map(&:first).uniq.sort, "at #{width}"
      assert shown.all? { |_, fits, _, _| fits }, "none cut short at #{width}: #{shown.reject { |_, fits, _, _| fits }.inspect}"
      assert shown.all? { |_, _, lines, _| lines == 1 }, "one line each at #{width}: #{shown.inspect}"
      assert_equal 1, shown.map(&:last).uniq.size, "one shared size at #{width}: #{shown.map(&:last).uniq.inspect}"
    end
  end
end
