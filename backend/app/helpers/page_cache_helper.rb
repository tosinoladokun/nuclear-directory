# A whole company or plant page, built once per data version (PM, 2 Nov:
# speed). What the page puts in the layout (title, description, head tags,
# its link-preview card) is kept with it and given back on a hit, so a cached
# page reads exactly as a fresh one. The key also has the host (the page has
# absolute URLs) and the template's own digest, so a code change rebuilds it.
#
#   <%= page_cache("company", @organization.id) do %> … the page … <% end %>
#
# The body is shared by every visitor: nothing per request goes inside it.
# A form (button_to, form_with) would share its CSRF token, so forms stay
# outside the block or load separately (Infra).
module PageCacheHelper
  CONTENTS = %i[title og_title og_description head].freeze
  Card = Data.define(:digest, :alt)
  EXPIRES = 1.day

  def page_cache(*name, &block)
    return capture(&block) unless controller.perform_caching

    key = cache_fragment_name([ "page/v1", *name, request.host, request.protocol, DataVersion.current ])
    if (stored = Rails.cache.read(key))
      stored[:contents].each { |content, value| content_for(content, value.html_safe) } # rubocop:disable Rails/OutputSafety
      @link_card = [ Card.new(**stored[:card][:card]), *stored[:card][:rest] ] if stored[:card]
      return stored[:html].html_safe # rubocop:disable Rails/OutputSafety
    end

    before = CONTENTS.to_h { |content| [ content, content_for(content).to_s ] }
    html = capture(&block)
    card, *rest = @link_card
    Rails.cache.write(key, {
      html: html.to_str,
      contents: CONTENTS.to_h { |content| [ content, content_for(content).to_s.delete_prefix(before[content]) ] }.compact_blank,
      card: (card && { card: { digest: card.digest, alt: card.alt }, rest: })
    }, expires_in: EXPIRES)
    html
  end
end
