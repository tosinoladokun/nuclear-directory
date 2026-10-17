require "test_helper"

class IconHelperTest < ActionView::TestCase
  test "inlines a decorative regular icon at 16px" do
    html = icon("magnifying-glass")

    assert_match(/\A<svg class="nd-ic" aria-hidden="true" focusable="false" /, html)
    assert_includes html, 'fill="currentColor"'
  end

  test "picks the weight and size" do
    html = icon("flag", weight: :bold, size: 12)

    assert_includes html, 'class="nd-ic nd-ic--12"'
    assert_equal File.read(IconHelper::ICON_ROOT.join("bold/flag.svg")).strip.sub("<svg ", ""), html.sub(/\A<svg [^>]*focusable="false" /, "")
  end

  test "adds extra classes and an accessible label" do
    html = icon("check", size: 12, label: "Verified", class: "ml-1")

    assert_includes html, 'class="nd-ic nd-ic--12 ml-1"'
    assert_includes html, 'role="img" aria-label="Verified"'
    assert_not_includes html, "aria-hidden"
  end

  test "rejects unknown icons, weights, sizes and path tricks" do
    assert_raises(ArgumentError) { icon("not-an-icon") }
    assert_raises(ArgumentError) { icon("flag", weight: :thin) }
    assert_raises(ArgumentError) { icon("flag", size: 18) }
    assert_raises(ArgumentError) { icon("../../../config/master") }
  end

  test "our own line icons: one per bucket and per kind of site, stroked in the text colour (#281)" do
    html = icon("bucket-fuel", set: :nd, size: 20)
    assert_includes html, 'class="nd-ic nd-ic--20"'
    assert_includes html, 'stroke="currentColor"'
    assert_includes html, 'fill="none"'

    Category.buckets.each { |bucket| assert IconHelper::ND_ICON_ROOT.join("bucket-#{bucket.key}.svg").file?, bucket.key }
    %w[plant pwr bwr advanced fusion research mine enrichment fuel waste].each do |kind|
      assert IconHelper::ND_ICON_ROOT.join("site-#{kind}.svg").file?, kind
    end
    assert_raises(ArgumentError) { icon("bucket-nope", set: :nd) }
    assert_raises(ArgumentError) { icon("flag", set: :other) }
  end

  test "every icon named in DESIGN.md exists in both weights" do
    %w[magnifying-glass sliders-horizontal graph buildings factory link arrow-square-out check clock x
       map-pin coins plug flag download-simple].each do |name|
      IconHelper::ICON_WEIGHTS.each do |weight|
        assert IconHelper::ICON_ROOT.join(weight, "#{name}.svg").file?, "missing #{weight}/#{name}.svg"
      end
    end
  end
end
