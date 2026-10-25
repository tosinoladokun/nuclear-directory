require "test_helper"

# Fonts: public pages in production keep font-display: optional (#474, no layout shift
# within the speed budget); admin and localhost use swap so the serif always loads.
class FontsTest < ActionView::TestCase
  test "admin and non-production pages use swap" do
    assert_includes render("shared/fonts", display: "swap"), "font-display: swap"
    assert_not_includes render("shared/fonts", display: "swap"), "font-display: optional"
    assert_includes render("shared/fonts"), "font-display: swap", "the test environment is not production"
  end

  test "production public pages keep optional for the two text fonts" do
    env = Rails.env
    Rails.env = "production"
    assert_equal 2, render("shared/fonts").scan("font-display: optional").size
  ensure
    Rails.env = env
  end
end
