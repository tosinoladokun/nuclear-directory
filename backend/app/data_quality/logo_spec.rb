# Company logos (#944): turns a company's logo file into the one-ink mask that
# DESIGN.md's "Company logos (#944)" spec describes, or rejects it with the
# reason. Every number and rule here is the spec's; change them there first.
#
#   result = DataQuality::LogoSpec.process(bytes, "image/svg+xml")
#   result.ok?        # => true
#   result.png        # PNG mask at 3× display size: black, with the mark in its alpha channel
#   result.kind       # => "symbol" or "wordmark"
#   result.steps      # => ["read SVG", "rendered at 4.2×", "one ink: …", …]
#   result.reason     # => nil, or why it was rejected
#
# Crawl calls it while it has the file in hand, and only a logo that passes
# becomes a candidate. Nothing here fetches, stores or knows about companies.
#
# Safety: SVGs are parsed against the spec's allow-list before anything draws
# them, and only that cleaned copy is rendered, by librsvg through libvips (no
# scripts, and no references outside the file survive the allow-list). Active
# Storage blocks libvips's "untrusted" loaders, the SVG one among them; only
# the buffer SVG loader is unblocked, right before it renders a cleaned copy.
# PNG and WebP are read by their own loaders, never by sniffing.
module DataQuality::LogoSpec
  MAX_BYTES = 500 * 1024
  # A small PNG can decode to gigabytes on a 512 MB instance.
  MAX_PIXELS = 25_000_000
  # Infra (25 Nov): the stored mask is at most 50 KB.
  MAX_PNG_BYTES = 50 * 1024
  SCALE = 3

  INK_ALPHA = 0.08 * 255
  INK_LIGHTNESS = 90
  SYMBOL_RATIO = 1.6
  WORDMARK_RATIO = 6.0
  SYMBOL_OPTICAL = 30.0
  SYMBOL_MAX_SIDE = 36.0
  WORDMARK_OPTICAL = 44.0
  WORDMARK_MAX_HEIGHT = 24.0
  MIN_COVERAGE = 0.15
  MAX_COVERAGE = 0.85
  # A disc 4.5px across in the 3× mask: offsets within 2.25px of the centre.
  THIN_DISC = Array.new(5) { |y| Array.new(5) { |x| ((x - 2)**2 + (y - 2)**2) <= 2.25**2 ? 255 : 128 } }.freeze

  # An SVG this tall or wide renders at most this many pixels on its long side.
  SVG_RENDER_SIDE = 2400

  SVG_NS = "http://www.w3.org/2000/svg"
  FILL = %w[fill fill-rule fill-opacity].freeze
  STROKE = %w[stroke stroke-width stroke-linecap stroke-linejoin stroke-miterlimit stroke-dasharray stroke-dashoffset stroke-opacity].freeze
  # clipPath is on the allow-list, so a shape may point at one and the clipPath needs an id to be pointed at.
  CLIP = %w[clip-path clip-rule].freeze
  PAINT = (FILL + STROKE + CLIP + %w[transform]).freeze
  ELEMENTS = {
    "svg" => %w[version id viewBox width height preserveAspectRatio],
    "g" => [],
    "defs" => [],
    "clipPath" => %w[id clipPathUnits],
    "path" => %w[d pathLength],
    "rect" => %w[x y width height rx ry],
    "circle" => %w[cx cy r],
    "ellipse" => %w[cx cy rx ry],
    "line" => %w[x1 y1 x2 y2],
    "polyline" => %w[points],
    "polygon" => %w[points]
  }.freeze
  # Read for checking and dropped before rendering: they draw nothing.
  DROPPED = %w[title desc metadata].freeze
  LOCAL_URL = /\Aurl\(\s*["']?#[\w.:-]+["']?\s*\)\z/

  Result = Data.define(:reason, :png, :kind, :width, :height, :steps, :multicolour, :source_type, :source_sha256) do
    def ok? = reason.nil?
    # Display size in CSS pixels; the PNG is SCALE times this.
    def png_sha256 = png && Digest::SHA256.hexdigest(png)
  end

  class Reject < StandardError; end

  def self.process(bytes, content_type = nil)
    steps = []
    bytes = bytes.to_s.b
    type = sniff(bytes, content_type)
    source = { source_type: type, source_sha256: Digest::SHA256.hexdigest(bytes) }
    raise Reject, "The file is #{bytes.bytesize / 1024} KB, over the 500 KB limit. Find a smaller SVG or PNG." if bytes.bytesize > MAX_BYTES

    image, rerender = case type
    when "svg" then render_svg(bytes, steps)
    when "png", "webp" then [ read_raster(bytes, type, steps), nil ]
    else raise Reject, "#{type_name(type)} isn't allowed: use SVG, or PNG or WebP with transparency"
    end

    finish(image, rerender: rerender, steps: steps, **source)
  rescue Reject => e
    Result.new(reason: e.message, png: nil, kind: nil, width: nil, height: nil, steps: steps, multicolour: nil,
      source_type: source&.dig(:source_type), source_sha256: source&.dig(:source_sha256))
  rescue Vips::Error => e
    Result.new(reason: "the file couldn't be read as an image (#{e.message.lines.first.to_s.strip})", png: nil, kind: nil,
      width: nil, height: nil, steps: steps, multicolour: nil,
      source_type: source&.dig(:source_type), source_sha256: source&.dig(:source_sha256))
  end

  def self.check(bytes, content_type = nil) = process(bytes, content_type)

  # The file's own bytes decide its type; a server's content type is often wrong.
  def self.sniff(bytes, content_type)
    head = bytes.byteslice(0, 16).to_s
    return "png" if head.start_with?("\x89PNG\r\n\x1A\n".b)
    return "webp" if head.start_with?("RIFF".b) && head.byteslice(8, 4) == "WEBP".b
    return "jpeg" if head.start_with?("\xFF\xD8\xFF".b)
    return "gif" if head.start_with?("GIF8".b)
    return "ico" if head.start_with?("\x00\x00\x01\x00".b)
    return "pdf" if head.start_with?("%PDF".b)
    return "eps" if head.start_with?("%!PS".b) || head.start_with?("\xC5\xD0\xD3\xC6".b)
    text = bytes.byteslice(0, 4096).to_s.dup.force_encoding("UTF-8").scrub.sub(/\A﻿/, "")
    return "svg" if text.match?(/<svg[\s>]/) || content_type.to_s.start_with?("image/svg")
    "unknown"
  end

  def self.type_name(type)
    { "jpeg" => "JPEG", "gif" => "GIF", "ico" => "ICO", "pdf" => "PDF", "eps" => "EPS" }.fetch(type, "This file type")
  end

  # --- SVG -----------------------------------------------------------------

  def self.render_svg(bytes, steps)
    clean = clean_svg(bytes)
    steps << "read SVG and checked it against the allow-list"
    Vips.block("VipsForeignLoadSvgBuffer", false)
    natural = Vips::Image.svgload_buffer(clean)
    long = [ natural.width, natural.height ].max
    raise Reject, "the SVG has no size" if long.zero?
    scale = SVG_RENDER_SIDE.to_f / long
    image = Vips::Image.svgload_buffer(clean, scale: scale)
    steps << "rendered the SVG at #{format('%.2f', scale)}× (#{image.width} × #{image.height}px) to measure it"
    # The spec: an SVG is rendered straight at the output size, never resampled.
    # factor is relative to the measuring render.
    rerender = lambda do |factor|
      # The whole canvas is drawn, so a small mark on a large canvas would be
      # drawn huge (a factor of 45 is about 108,000px a side): refused first (Infra, #946).
      width = (natural.width * scale * factor).ceil
      height = (natural.height * scale * factor).ceil
      if width * height > MAX_PIXELS
        raise Reject, "the mark is a small part of a large SVG canvas (#{width} × #{height}px at the output size); " \
          "use a file cropped to the logo"
      end
      Vips.block("VipsForeignLoadSvgBuffer", false)
      srgb_with_alpha(Vips::Image.svgload_buffer(clean, scale: scale * factor))
    end
    [ srgb_with_alpha(image), rerender ]
  end

  def self.clean_svg(bytes)
    text = bytes.dup.force_encoding("UTF-8")
    raise Reject, "the SVG isn't valid UTF-8 text" unless text.valid_encoding?
    # Entities can expand or reach outside the file; a plain DOCTYPE is dropped.
    raise Reject, "the SVG declares entities, which the logo spec doesn't allow" if text.match?(/<!ENTITY/i)
    doc = Nokogiri::XML(text) { |config| config.strict.nonet }
    root = doc.root
    raise Reject, "the file isn't an SVG" unless root&.name == "svg" && root.namespace&.href == SVG_NS
    doc.internal_subset&.remove
    doc.xpath("//processing-instruction()").each(&:remove)
    check_node(root)
    check_clip_references(root)
    root.xpath(".//svg:title | .//svg:desc | .//svg:metadata | .//comment()", "svg" => SVG_NS).each(&:remove)
    root.to_xml
  rescue Nokogiri::XML::SyntaxError => e
    raise Reject, "the SVG isn't well-formed XML (#{e.message.lines.first.to_s.strip})"
  end

  def self.check_node(node)
    node.element_children.each do |child|
      name = child.name
      unless child.namespace&.href == SVG_NS
        raise Reject, "the SVG has a <#{[ child.namespace&.prefix, name ].compact.join(':')}> element, which the logo spec doesn't allow"
      end
      next if DROPPED.include?(name)
      raise Reject, "the SVG has a <#{name}> element, which the logo spec doesn't allow" unless ELEMENTS.key?(name)
      check_attributes(child)
      check_node(child)
    end
    check_attributes(node) if node.name == "svg" && node.parent.is_a?(Nokogiri::XML::Document)
  end

  # A url() may only be a clip-path pointing at a clipPath in the same file
  # (#945): a missing target, or one that isn't a clipPath, is rejected.
  def self.check_clip_references(root)
    clip_ids = root.xpath(".//svg:clipPath[@id]", "svg" => SVG_NS).map { |node| node["id"] }
    root.xpath("descendant-or-self::*[@*[contains(., 'url(')]]").each do |element|
      element.attribute_nodes.select { |attr| attr.value.include?("url(") }.each do |attr|
        unless attr.name == "clip-path"
          raise Reject, "the SVG has a url() in #{attr.name} on <#{element.name}>; only a clip-path may point inside the file"
        end
        target = attr.value[/#([\w.:-]+)/, 1]
        unless clip_ids.include?(target)
          raise Reject, "the SVG's clip-path on <#{element.name}> points to ##{target}, which isn't a clipPath in the file"
        end
      end
    end
  end

  def self.check_attributes(element)
    allowed = ELEMENTS.fetch(element.name) + PAINT
    element.attribute_nodes.each do |attr|
      name = attr.namespace ? "#{attr.namespace.prefix}:#{attr.name}" : attr.name
      value = attr.value.to_s
      raise Reject, "the SVG has an #{name} attribute (a script), which the logo spec doesn't allow" if attr.name.downcase.start_with?("on")
      if attr.name == "href"
        raise Reject, "the SVG has an #{name} that points outside the file" unless value.start_with?("#")
        raise Reject, "the SVG has an #{name} attribute on <#{element.name}>, which the logo spec doesn't allow"
      end
      if value.include?("url(") && !value.strip.match?(LOCAL_URL)
        raise Reject, "the SVG has a url() that points outside the file (#{name} on <#{element.name}>)"
      end
      raise Reject, "the SVG uses a #{name} attribute, which the logo spec doesn't allow" if %w[style class].include?(name)
      next if allowed.include?(name)
      raise Reject, "the SVG has a #{name} attribute on <#{element.name}>, which the logo spec doesn't allow"
    end
    # Namespace declarations (xmlns, xmlns:*) aren't attribute nodes; only <svg> may carry them.
    if element.name != "svg" && element.namespace_definitions.any?
      raise Reject, "the SVG declares a namespace on <#{element.name}>, which the logo spec doesn't allow"
    end
  end

  # --- PNG and WebP --------------------------------------------------------

  def self.read_raster(bytes, type, steps)
    image = type == "png" ? Vips::Image.pngload_buffer(bytes) : Vips::Image.webpload_buffer(bytes)
    if image.width * image.height > MAX_PIXELS
      raise Reject, "the image is #{image.width} × #{image.height}px, more than #{MAX_PIXELS / 1_000_000} million pixels"
    end
    raise Reject, "the #{type.upcase} has no transparency" unless image.has_alpha?
    image = srgb_with_alpha(image)
    steps << "read #{type.upcase} (#{image.width} × #{image.height}px)"
    alpha = image.extract_band(3)
    corners = [ [ 0, 0 ], [ image.width - 1, 0 ], [ 0, image.height - 1 ], [ image.width - 1, image.height - 1 ] ]
    if corners.any? { |x, y| alpha.getpoint(x, y).first >= 255 }
      raise Reject, "a corner is opaque: the image has a background, not transparency"
    end
    steps << "checked the four corners are transparent"
    image
  end

  def self.srgb_with_alpha(image)
    image = image.colourspace(:srgb) unless image.interpretation == :srgb
    image = image.cast(:uchar) unless image.format == :uchar
    image = image.bandjoin(255) unless image.has_alpha?
    image.bands > 4 ? image.extract_band(0, n: 4) : image
  end

  # --- One ink, trim, size, checks ----------------------------------------

  # One ink: a pixel with alpha of 8% or more and L* of 90 or less becomes ink,
  # fully opaque (the spec allows no opacity); the rest is transparent. A
  # raster's edges are smoothed again by the scaling step.
  def self.one_ink(image)
    rgb = image.extract_band(0, n: 3)
    alpha = image.extract_band(3)
    lightness = rgb.colourspace(:lab).extract_band(0)
    ink = (alpha >= INK_ALPHA) & (lightness <= INK_LIGHTNESS)
    [ ink.ifthenelse(255, 0).cast(:uchar), rgb, ink ]
  end

  def self.finish(image, rerender:, steps:, source_type:, source_sha256:)
    mask, rgb, ink = one_ink(image)
    steps << "one ink: kept pixels with alpha of 8% or more and L* of 90 or less"
    raise Reject, "the one-ink version is empty (a logo made for dark backgrounds?)" if mask.max.zero?

    multicolour = multicolour?(rgb, ink)
    left, top, width, height = mask.find_trim(threshold: 0, background: [ 0 ])
    mask = mask.crop(left, top, width, height)
    steps << "trimmed to the ink (#{width} × #{height}px)"

    ratio = width.to_f / height
    kind = if ratio <= SYMBOL_RATIO && ratio >= 1 / SYMBOL_RATIO then "symbol"
    elsif ratio > SYMBOL_RATIO && ratio <= WORDMARK_RATIO then "wordmark"
    end
    unless kind
      shape = ratio > 1 ? "#{format('%.1f', ratio)}:1 wide" : "#{format('%.1f', 1 / ratio)} times taller than wide"
      raise Reject, "the mark is #{shape}; a logo is at most 6:1 wide or 1.6 times taller than wide"
    end
    display_w, display_h = display_size(kind, width, height)
    out_w = (display_w * SCALE).round
    out_h = (display_h * SCALE).round
    steps << "#{kind}, #{format('%.2f', ratio)}:1, shown at #{format('%.1f', display_w)} × #{format('%.1f', display_h)}px"
    if rerender.nil? && (width < out_w || height < out_h)
      raise Reject, "the mark is #{width} × #{height}px; it needs at least #{out_w} × #{out_h}px (3× its display size), and it's never enlarged"
    end

    # Scaling is even: one factor for both sides. Rounding to whole pixels can
    # leave a pixel's difference, which is cropped or padded, never stretched.
    factor = display_w * SCALE / width
    if rerender
      mask = one_ink(rerender.call(factor)).first
      left, top, trimmed_w, trimmed_h = mask.find_trim(threshold: 0, background: [ 0 ])
      mask = mask.crop(left, top, trimmed_w, trimmed_h)
      steps << "rendered the SVG at the output size"
    else
      mask = mask.resize(factor, kernel: :lanczos3)
      steps << "scaled down evenly"
    end
    mask = mask.crop(0, 0, [ mask.width, out_w ].min, [ mask.height, out_h ].min)
    mask = mask.embed(0, 0, out_w, out_h) if mask.width < out_w || mask.height < out_h
    steps << "#{out_w} × #{out_h}px mask (3×)"

    coverage = mask.avg / 255.0
    if coverage < MIN_COVERAGE || coverage > MAX_COVERAGE
      raise Reject, "the ink covers #{(coverage * 100).round}% of the mark's box; a logo covers 15% to 85%"
    end
    steps << "ink covers #{(coverage * 100).round}% of the box"
    raise Reject, "part of the mark is thinner than 1.5px at display size" if thin_part?(mask)
    steps << "every part is at least 1.5px thick at display size"

    png = Vips::Image.black(out_w, out_h).bandjoin(mask).copy(interpretation: :b_w)
      .pngsave_buffer(compression: 9, strip: true)
    raise Reject, "the processed logo is #{png.bytesize / 1024} KB, over the 50 KB limit" if png.bytesize > MAX_PNG_BYTES

    Result.new(reason: nil, png: png, kind: kind, width: display_w.round(1), height: display_h.round(1), steps: steps,
      multicolour: multicolour, source_type: source_type, source_sha256: source_sha256)
  end

  # The spec's optical sizes are targets: a symbol to √(w·h) = 30, a wordmark to
  # √(w·h) = 44. A cap (a symbol's longer side 36, a wordmark's height 24) only
  # ever scales the mark down evenly from its target.
  def self.display_size(kind, width, height)
    optical = kind == "symbol" ? SYMBOL_OPTICAL : WORDMARK_OPTICAL
    scale = optical / Math.sqrt(width * height)
    scale = [ scale, SYMBOL_MAX_SIDE / [ width, height ].max ].min if kind == "symbol"
    scale = [ scale, WORDMARK_MAX_HEIGHT / height ].min if kind == "wordmark"
    [ width * scale, height * scale ]
  end

  # Rule 6: thresholded at alpha 50%, a connected shape that vanishes entirely
  # under erosion by the 4.5px disc is thinner than 1.5px at display size all
  # the way through. A shape that only thins out at its ends keeps its core.
  def self.thin_part?(mask)
    # A clear margin, so a shape touching the trimmed edge erodes from that side too.
    solid = (mask >= 128).embed(3, 3, mask.width + 6, mask.height + 6)
    labels = solid.labelregions
    return false if labels.max >= 65_535
    labels = labels.cast(:ushort)
    ones = (solid / 255).cast(:uchar)
    kept = (solid.morph(THIN_DISC, :erode) / 255).cast(:uchar)
    before = ones.hist_find_indexed(labels).to_a.flatten
    after = kept.hist_find_indexed(labels).to_a.flatten
    before.each_with_index.any? { |count, i| count.positive? && after[i].to_f.zero? }
  end

  # More than one colour among the ink (flagged for Tosin at approval). Every
  # ink pixel counts. Colours are grouped by distance in CIELAB: a colour joins
  # the first group whose centre is within 10 (ΔE76) and otherwise starts its
  # own, so two colours over 20 apart never share a group. A group that makes
  # up at least 3% of the ink counts, and two counted groups over 20 apart
  # make the source multicolour.
  def self.multicolour?(rgb, ink)
    small = 256.0 / [ rgb.width, rgb.height ].max
    if small < 1
      rgb = rgb.resize(small, kernel: :nearest)
      ink = ink.resize(small, kernel: :nearest)
    end
    lab = rgb.colourspace(:lab)
    pixels = lab.bandjoin(ink).to_a.flatten(1).select { |px| px[3].to_i >= 128 }.map { |px| px.first(3) }
    return false if pixels.empty?
    # Exact colours first, most common first, so a group's centre is its main colour.
    colours = pixels.tally.sort_by { |_, count| -count }
    groups = []
    colours.each do |colour, count|
      group = groups.find { |g| distance(g[:centre], colour) <= 10 }
      group ? group[:count] += count : groups << { centre: colour, count: count }
    end
    counted = groups.select { |g| g[:count] >= pixels.size * 0.03 }.map { |g| g[:centre] }
    counted.combination(2).any? { |c1, c2| distance(c1, c2) > 20 }
  end

  def self.distance(c1, c2) = Math.sqrt(c1.zip(c2).sum { |x, y| (x - y)**2 })
end
