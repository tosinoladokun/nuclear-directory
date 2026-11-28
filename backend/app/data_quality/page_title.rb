# Pulls a human-readable title out of a fetched page: its <title>, or
# og:title when <title> is missing. Whitespace is tidied, entities decoded
# and very long titles cut. Non-HTML responses (PDF, text) have no title.
#
#   DataQuality::PageTitle.from(html, content_type: "text/html") # => "Kairos Power breaks ground…"
module DataQuality::PageTitle
  MAX_LENGTH = 300
  # Script, style and inline-SVG blocks: dropped, as text, before any parse, so a page's own text and head aren't
  # pushed past a cap by inline code (Copilot, #1032).
  CODE_BLOCKS = %r{<(script|style|noscript|svg)\b[^>]*>.*?</\1\s*>}mi
  # At most this much of a page is parsed for its title: its <head>, without its code, never a whole page of
  # several MB (the web process's memory, #1026).
  SCAN = 200_000

  # A page's HTML without its code blocks, cut to at most `bytes`: plain strings, never a parsed document.
  def self.without_code(html, bytes:)
    html.to_s.gsub(CODE_BLOCKS, " ").byteslice(0, bytes).to_s.scrub
  end

  def self.from(body, content_type:)
    return unless html?(body, content_type)

    html = without_code(body, bytes: SCAN)
    # Only its head when it has one: the title and og:title live there.
    head_end = html.index(%r{</head\s*>}i)
    doc = Nokogiri::HTML(head_end ? html[0, head_end] : html)
    title = doc.at_css("head title, title")&.text.presence ||
      doc.at_css('meta[property="og:title"]')&.[]("content")
    title = title.to_s.squish
    title.truncate(MAX_LENGTH, separator: " ") if title.present?
  end

  def self.html?(body, content_type)
    return content_type.to_s.match?(%r{html}i) if content_type.present?

    body.to_s.lstrip.first(200).match?(/<(!doctype html|html|head|title)\b/i)
  end
  private_class_method :html?
end
