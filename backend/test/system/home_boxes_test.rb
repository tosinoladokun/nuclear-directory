require "application_system_test_case"
require_relative "../support/directory_builders"

# Text inside a box never wraps or hyphenates (Tosin, 17 Oct): a home box's
# title shrinks to fit instead, at phone and desktop widths.
class HomeBoxesTest < ApplicationSystemTestCase
  include DirectoryBuilders

  # Each title's line count and whether its text is cut short.
  TITLES = <<~JS
    [...document.querySelectorAll(".nd-cat__name")].map((el) => {
      const lines = Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight));
      return [el.textContent, lines, el.scrollWidth > el.clientWidth, parseFloat(getComputedStyle(el).fontSize)];
    })
  JS

  setup do
    %w[components waste_decommissioning reactor_vendor].each { |key| cite!(company("Co #{key}", roles: [ role(key) ])) }
  end

  [ [ 390, 844 ], [ 768, 1024 ], [ 1024, 768 ], [ 1440, 900 ] ].each do |width, height|
    test "no box title wraps or is cut short at #{width}" do
      visit root_path
      resize_viewport(width, height)

      titles = page.evaluate_script(TITLES)
      assert_includes titles.map(&:first), "Components and manufacturing"
      assert_includes titles.map(&:first), "Waste and decommissioning"
      titles.each do |text, lines, cut, size|
        assert_equal 1, lines, "#{text} wraps at #{width}"
        assert_not cut, "#{text} is cut short at #{width}"
        assert_operator size, :>=, 13, "#{text} is smaller than 13px at #{width}"
      end
    end
  end
end
