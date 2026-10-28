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

    [ "Roboto Serif Georgia", "Roboto Serif Times", "Roboto Serif DejaVu", "Roboto Mono Menlo", "Roboto Mono Courier", "Roboto Mono DejaVu" ].each do |family|
      faces = html.scan(/@font-face \{ font-family: "#{family}"[^}]*\}/)
      assert faces.any?, "#{family} is declared"
      faces.each do |face|
        assert_match(/src: local\(/, face)
        %w[size-adjust ascent-override descent-override line-gap-override].each { |descriptor| assert_includes face, descriptor, "#{family} #{descriptor}" }
      end
    end
    %w[Georgia Times DejaVu].each { |family| assert_equal 2, html.scan(/font-family: "Roboto Serif #{family}"/).size, "#{family}: a regular face and a bold one" }
    tokens = Rails.root.join("app/assets/tailwind/design_system/tokens.css").read
    assert_match(/--font-text: "Roboto Serif", "Roboto Serif Georgia", "Roboto Serif Times", "Roboto Serif DejaVu", Georgia, serif;/, tokens)
    assert_match(/--font-mono: "Roboto Mono", "Roboto Mono Menlo", "Roboto Mono Courier", "Roboto Mono DejaVu"/, tokens)
  end
end
