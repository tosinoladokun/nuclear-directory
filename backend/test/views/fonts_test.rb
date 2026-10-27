require "test_helper"

# Fonts (Tosin, 27 Oct): the real fonts always show, so the two text fonts swap in, and metric-matched local
# fallbacks (size-adjust and the ascent, descent and line-gap overrides) keep the swap from moving the page.
class FontsTest < ActionView::TestCase
  test "Roboto Serif and Roboto Mono are font-display: swap, never optional" do
    html = render("shared/fonts")

    assert_match(/font-family: "Roboto Serif"[^}]*font-display: swap/, html)
    assert_match(/font-family: "Roboto Mono"[^}]*font-display: swap/, html)
    assert_not_includes html, "font-display: optional"
  end

  test "each text font has local fallbacks with its metrics, and the stacks name them after the real font" do
    html = render("shared/fonts")

    [ "Roboto Serif Georgia", "Roboto Serif Times", "Roboto Mono Menlo", "Roboto Mono Courier" ].each do |family|
      face = html[/@font-face \{ font-family: "#{family}"[^}]*\}/]
      assert face, "#{family} is declared"
      assert_match(/src: local\(/, face)
      %w[size-adjust ascent-override descent-override line-gap-override].each { |descriptor| assert_includes face, descriptor, "#{family} #{descriptor}" }
    end
    tokens = Rails.root.join("app/assets/tailwind/design_system/tokens.css").read
    assert_match(/--font-text: "Roboto Serif", "Roboto Serif Georgia", "Roboto Serif Times", Georgia, serif;/, tokens)
    assert_match(/--font-mono: "Roboto Mono", "Roboto Mono Menlo", "Roboto Mono Courier"/, tokens)
  end
end
