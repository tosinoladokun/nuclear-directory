require "test_helper"

class DataQuality::PageTitleTest < ActiveSupport::TestCase
  def title(body, content_type: "text/html; charset=utf-8") = DataQuality::PageTitle.from(body, content_type:)

  test "reads <title>, tidying whitespace and decoding entities" do
    html = "<html><head><title>\n  Kairos Power &amp; TVA   sign\n deal | Kairos Power </title></head></html>"

    assert_equal "Kairos Power & TVA sign deal | Kairos Power", title(html)
  end

  test "falls back to og:title" do
    html = '<html><head><meta property="og:title" content="X-energy picks Texas site"></head></html>'

    assert_equal "X-energy picks Texas site", title(html)
  end

  test "no title, no HTML, no answer" do
    assert_nil title("<html><head><title>  </title></head><body>Hi</body></html>")
    assert_nil title("%PDF-1.7 …", content_type: "application/pdf")
    assert_nil title("ReportDt|Unit|Power", content_type: "text/plain")
  end

  test "recognises HTML without a content type" do
    assert_equal "Untyped", title("<!DOCTYPE html><html><title>Untyped</title></html>", content_type: nil)
  end

  test "cuts very long titles at a word" do
    long = title("<title>#{'word ' * 200}</title>")

    assert long.length <= DataQuality::PageTitle::MAX_LENGTH
    assert long.end_with?("...")
  end

  test "only the head is parsed, without its code: a 450 KB inline script before the title, or a huge body, doesn't hide it (Copilot, #1032)" do
    script = "<script>#{'var x = 1;' * 45_000}</script>"
    html = "<html><head>#{script}<title>Acme Fission</title></head><body>#{'<p>filler</p>' * 400_000}</body></html>"
    assert_operator html.bytesize, :>, 5_000_000
    assert_equal "Acme Fission", DataQuality::PageTitle.from(html, content_type: "text/html")
    assert_operator DataQuality::PageTitle.without_code(html, bytes: 1_000).bytesize, :<=, 1_000
    assert_not_includes DataQuality::PageTitle.without_code(html, bytes: 10_000), "var x"
  end
end
