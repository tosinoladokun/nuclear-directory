require "test_helper"

# #944: DESIGN.md's "Company logos" spec, enforced in code. Each test names the
# spec rule it covers.
class DataQuality::LogoSpecTest < ActiveSupport::TestCase
  def svg(body, view: "0 0 100 100", attrs: "")
    %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="#{view}" #{attrs}>#{body}</svg>)
  end

  # A round symbol: a disc covers π/4 (79%) of its box.
  DISC = '<circle cx="50" cy="50" r="40" fill="#111"/>'.freeze
  # A 4:1 wordmark: four bars over half the width.
  BARS = %w[0 100 200 350].map { |x| %(<rect x="#{x}" y="0" width="50" height="100" fill="#000"/>) }.join.freeze

  def process(bytes, type = nil) = DataQuality::LogoSpec.process(bytes, type)

  def assert_rejected(result, pattern)
    assert_not result.ok?, "expected a rejection matching #{pattern.inspect}"
    assert_match pattern, result.reason
  end

  # A PNG of bars, with the given alpha in the gaps and corners.
  def bars_png(width, height, background: 0, alpha: true)
    image = Vips::Image.black(width, height, bands: 3).bandjoin(background)
    # Inset 4px, so the corners stay transparent.
    [ 0, 0.25, 0.5, 0.86 ].each { |f| image = image.draw_rect([ 0, 0, 0, 255 ], 4 + (width * f).round, 4, (width * 0.12).round, height - 8, fill: true) }
    image = image.extract_band(0, n: 3) unless alpha
    image.pngsave_buffer
  end

  test "a symbol: √(w·h) = 30px, stored at 3× as a black PNG with the mark in its alpha" do
    result = process(svg(DISC), "image/svg+xml")
    assert result.ok?, result.reason
    assert_equal "symbol", result.kind
    assert_equal [ 30.0, 30.0 ], [ result.width, result.height ]
    png = Vips::Image.new_from_buffer(result.png, "")
    assert_equal [ 90, 90, 2 ], [ png.width, png.height, png.bands ]
    assert_equal 0, png.extract_band(0).max, "the colour band is black; the theme's ink comes from CSS"
    assert_operator result.png.bytesize, :<=, 50 * 1024
    assert_equal Digest::SHA256.hexdigest(result.png), result.png_sha256
    assert_equal "svg", result.source_type
    assert result.steps.any? { |step| step.start_with?("one ink") }
    assert_not result.multicolour
  end

  test "a wordmark: √(w·h) = 44px with the height capped at 24px" do
    result = process(svg(BARS, view: "0 0 400 100"))
    assert result.ok?, result.reason
    assert_equal "wordmark", result.kind
    assert_equal [ 88.0, 22.0 ], [ result.width, result.height ], "4:1 is 88 × 22"
    assert_equal [ 264, 66 ], Vips::Image.new_from_buffer(result.png, "").then { |r| [ r.width, r.height ] }

    two_to_one = svg('<rect x="0" y="0" width="80" height="100"/><rect x="120" y="0" width="80" height="100"/>', view: "0 0 200 100")
    assert_equal [ 48.0, 24.0 ], process(two_to_one).then { |r| [ r.width, r.height ] }, "2:1 is 48 × 24 (height cap)"
  end

  test "a symbol's longest side is at most 36px" do
    tall = svg('<rect x="0" y="0" width="20" height="96"/><rect x="40" y="0" width="20" height="96"/>', view: "0 0 60 96")
    result = process(tall)
    assert result.ok?, result.reason
    assert_in_delta 36.0, result.height, 0.1
  end

  test "rule 4: wider than 6:1 or more than 1.6 times taller than wide" do
    assert_rejected process(svg('<rect x="0" y="0" width="700" height="100"/>', view: "0 0 700 100")), /7\.0:1 wide/
    assert_rejected process(svg('<rect x="0" y="0" width="50" height="100"/>', view: "0 0 50 100")), /taller than wide/
  end

  test "rule 5: the ink covers 15% to 85% of the trimmed box" do
    assert_rejected process(svg('<rect x="0" y="0" width="100" height="100"/>')), /covers 100%/
    ring = '<circle cx="50" cy="50" r="45" fill="none" stroke="#000" stroke-width="2"/>'
    assert_rejected process(svg(ring)), /covers \d%/
  end

  test "rule 6: a part thinner than 1.5px all the way through; corners don't count" do
    # A disc and a separate bar 3 units wide: 2.7px in the 90px mask, under 4.5px.
    thin = '<circle cx="40" cy="50" r="40"/><rect x="95" y="10" width="3" height="80"/>'
    assert_rejected process(svg(thin)), /thinner than 1\.5px/
    assert process(svg('<polygon points="0,0 100,50 0,100"/>')).ok?, "a sharp point thins out but the shape stays"
  end

  test "rule 7: an empty one-ink version (white, or lighter than L* 90)" do
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" fill="#fff"/>')), /empty/
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" fill="#eee"/>')), /empty/
    assert process(svg('<circle cx="50" cy="50" r="40" fill="#c00"/>')).ok?, "a colour darker than L* 90 is ink"
  end

  test "a white knockout inside a mark stays a hole" do
    result = process(svg(DISC + '<circle cx="50" cy="50" r="15" fill="#fff"/>'))
    assert result.ok?, result.reason
    assert_equal 0, Vips::Image.new_from_buffer(result.png, "").extract_band(1).getpoint(45, 45).first
  end

  test "more than one colour is flagged" do
    assert process(svg('<rect x="0" y="0" width="35" height="100" fill="#000"/><rect x="65" y="0" width="35" height="100" fill="#c00"/>')).multicolour
  end

  test "SVG allow-list: elements" do
    { "<script>alert(1)</script>" => /<script>/, "<style>rect{}</style>" => /<style>/,
      '<image href="https://x.test/a.png" width="10" height="10"/>' => /<image>/, "<text>Acme</text>" => /<text>/,
      '<use href="#a"/>' => /<use>/, "<foreignObject/>" => /<foreignObject>/,
      '<linearGradient id="g"/>' => /<linearGradient>/, '<filter id="f"/>' => /<filter>/,
      '<mask id="m"/>' => /<mask>/, '<pattern id="p"/>' => /<pattern>/, '<animate attributeName="x"/>' => /<animate>/ }.each do |body, reason|
      assert_rejected process(svg(DISC + body)), reason
    end
    inkscape = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" viewBox="0 0 100 100"><sodipodi:namedview/>' + DISC + "</svg>"
    assert_rejected process(inkscape), /<sodipodi:namedview>/
  end

  test "SVG allow-list: attributes, scripts and references outside the file" do
    assert_rejected process(svg(DISC, attrs: 'onload="alert(1)"')), /onload attribute \(a script\)/
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" onclick="x()"/>')), /onclick/
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" style="fill:red"/>')), /style attribute/
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" class="a"/>')), /class attribute/
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" fill="url(https://x.test/p.svg#g)"/>')), /url\(\) that points outside/
    assert_rejected process(svg('<circle cx="50" cy="50" r="40" opacity="0.5"/>')), /opacity attribute on <circle>/
    assert_rejected process(svg(DISC, attrs: 'x="0px"')), /x attribute on <svg>/
    xlink = '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100"><g xlink:href="https://x.test/"/>' + DISC + "</svg>"
    assert_rejected process(xlink), /xlink:href that points outside the file/
    entity = %(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]>) + svg(DISC)
    assert_rejected process(entity), /entities/
  end

  test "SVG allow-list: what draws nothing is allowed and dropped, and a clipPath inside the file works" do
    doctype = %(<?xml version="1.0"?><!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">)
    body = '<title>Acme</title><desc>Logo</desc><metadata><x xmlns="urn:x">y</x></metadata><!-- c -->' \
      '<defs><clipPath id="c"><rect x="0" y="0" width="100" height="70"/></clipPath></defs>' \
      '<g transform="translate(0 0)"><circle cx="50" cy="50" r="40" clip-path="url(#c)" fill-rule="evenodd"/></g>'
    result = process(doctype + svg(body, attrs: 'xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" id="logo" width="100" height="100" preserveAspectRatio="xMidYMid"'))
    assert result.ok?, result.reason
  end

  test "PNG with transparency: read, corners checked, never enlarged" do
    result = process(bars_png(400, 100), "image/png")
    assert result.ok?, result.reason
    assert_equal [ "wordmark", "png" ], [ result.kind, result.source_type ]

    assert_rejected process(bars_png(100, 25)), /needs at least \d+ × \d+px \(3× its display size\), and it's never enlarged/
    assert_rejected process(bars_png(400, 100, background: 255)), /corner is opaque/
    assert_rejected process(bars_png(400, 100, alpha: false)), /no transparency/
  end

  test "WebP with transparency is read too" do
    webp = Vips::Image.new_from_buffer(bars_png(400, 100), "").webpsave_buffer(lossless: true)
    result = process(webp, "image/webp")
    assert result.ok?, result.reason
    assert_equal "webp", result.source_type
  end

  test "file types and size: the bytes decide the type, not the server" do
    assert_rejected process("\xFF\xD8\xFF\xE0rest".b, "image/png"), /JPEG isn't allowed/
    assert_rejected process("GIF89a....".b), /GIF isn't allowed/
    assert_rejected process("\x00\x00\x01\x00....".b), /ICO isn't allowed/
    assert_rejected process("%PDF-1.7".b), /PDF isn't allowed/
    assert_rejected process("%!PS-Adobe-3.0 EPSF".b), /EPS isn't allowed/
    assert process(svg(DISC), "text/plain").ok?, "an SVG served as text is still an SVG"
    assert_rejected process(svg(DISC + "<!-- #{'x' * 500 * 1024} -->")), /\AThe file is \d+ KB, over the 500 KB limit\. Find a smaller SVG or PNG\.\z/
    assert_rejected process("<svg xmlns='http://www.w3.org/2000/svg'><g>"), /well-formed/
  end
end
