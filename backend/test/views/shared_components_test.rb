require "test_helper"

# The shared components (#558) in isolation: escaping, and rows that keep their slots.
class SharedComponentsTest < ActionView::TestCase
  helper DirectoryHelper, IconHelper

  test "a glance value is escaped in its title, and the label comes first" do
    html = render("shared/glance", facts: [ { label: "Headquarters", value: 'Acme" onmouseover="alert(1)' } ])

    dd = Nokogiri::HTML.fragment(html).at_css("dd")
    assert_equal [ "title" ], dd.attributes.keys, "the value can't add an attribute"
    assert_equal 'Acme" onmouseover="alert(1)', dd["title"]
    assert_select_in html, "dt + dd", 1
  end

  test "a bare row keeps its description and location columns when a value is missing" do
    html = render("shared/line", variant: :bare, name: "Oklo", href: "/x")

    assert_select_in html, ".nd-line--bare .nd-line__what", 1
    assert_select_in html, ".nd-line--bare .nd-line__end", 1
  end

  test "a company row's long name stays full size: its short name, or an ellipsis, never 13px" do
    html = render("shared/line", variant: :bare, name: "Breakthrough Energy Ventures Holdings", short_name: "Breakthrough Energy", href: "/x")
    assert_select_in html, ".nd-line__name[data-fit=small]", 0
    assert_select_in html, ".nd-line__name", 1
    assert_includes html, ">Breakthrough Energy<"
    assert_includes html, 'title="Breakthrough Energy Ventures Holdings"'
    plain = render("shared/line", variant: :bare, name: "Commonwealth Fusion Systems Incorporated", href: "/x")
    assert_select_in plain, ".nd-line__name[data-fit=small]", 0
  end

  test "a long plant name also drops to the small size" do
    html = render("shared/line", name: "Tennessee Valley Authority Watts Bar", href: "/x")

    assert_select_in html, ".nd-line__name[data-fit=small]", 1
  end

  def assert_select_in(html, selector, count) = assert_equal(count, Nokogiri::HTML.fragment(html).css(selector).size, "#{selector} in #{html}")
end
