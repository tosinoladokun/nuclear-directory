require "application_system_test_case"
require_relative "../support/directory_builders"

# Home card titles are shown in full (Tosin, 31 Oct): never an ellipsis, never a short name, even in a wider fallback font.
class HomeCardTitlesTest < ApplicationSystemTestCase
  include DirectoryBuilders

  setup do
    %w[reactor_vendor fuel components waste_decommissioning utility data_center_offtaker reactor_services venture_capital government_agency].each do |key|
      cite!(company("#{key.humanize} Company", roles: [ role(key) ]))
    end
    cite!(plant("Some Station", facility_type: "power_reactor", status: "operating"))
  end

  FULL = [ "Reactor Developers", "Fuel and Materials", "Components and Parts", "Waste and Decommissioning", "Power Plant Owners and Operators",
           "Power Buyers", "Services and Engineering", "Investors", "Government and Research", "Plants and Sites" ].freeze

  test "every title reads in full, none cut short, at phone, tablet and desktop widths and in a wide fallback font" do
    [ 360, 390, 768, 1024, 1280, 1440 ].each do |width|
      [ false, true ].each do |wide_font|
        resize_viewport(width, 900)
        visit root_path
        page.execute_script("document.head.insertAdjacentHTML('beforeend', '<style>.nd-catcard__name { font-family: Georgia, \"DejaVu Serif\", serif !important; letter-spacing: 0.02em !important }</style>')") if wide_font
        sleep 0.2
        shown = page.evaluate_script("[...document.querySelectorAll('.nd-catcard__name')].filter((n) => n.getClientRects().length).map((n) => [n.textContent.trim(), n.scrollWidth <= n.clientWidth + 1, Math.round(n.getBoundingClientRect().height / parseFloat(getComputedStyle(n).lineHeight))])")
        assert_equal FULL.sort, shown.map(&:first).uniq.sort, "at #{width}"
        assert shown.all? { |_, fits, _| fits }, "none cut short at #{width}#{' (wide font)' if wide_font}: #{shown.reject { |_, fits, _| fits }.inspect}"
        assert shown.all? { |_, _, lines| lines <= 2 }, "at most two lines at #{width}#{' (wide font)' if wide_font}: #{shown.inspect}"
      end
    end
  end
end
