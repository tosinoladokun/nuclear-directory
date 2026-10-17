# Inlines an icon so it inherits the text color (an <img> can't).
# Phosphor icons live in app/assets/images/icons/phosphor/{regular,bold}/<name>.svg;
# our own line icons (the buckets and kinds of site, #281) in icons/nd/<name>.svg,
# drawn with a 2px stroke in currentColor. See DESIGN.md, "Iconography".
#
#   icon("magnifying-glass")                     # 16px, regular, decorative
#   icon("flag", weight: :bold)                  # on the black profile banner
#   icon("check", size: 12, label: "Verified")   # announced to screen readers
#   icon("bucket-fuel", set: :nd)                # a line icon of our own
module IconHelper
  ICON_ROOT = Rails.root.join("app/assets/images/icons/phosphor")
  ND_ICON_ROOT = Rails.root.join("app/assets/images/icons/nd")
  ICON_WEIGHTS = %w[regular bold].freeze
  ICON_SIZES = [ 12, 16, 20, 24 ].freeze
  ICON_CACHE = Concurrent::Map.new

  def icon(name, weight: :regular, size: 16, label: nil, set: :phosphor, **options)
    name = name.to_s
    weight = weight.to_s
    raise ArgumentError, "unknown icon name: #{name.inspect}" unless name.match?(/\A[a-z0-9-]+\z/)
    raise ArgumentError, "unknown icon weight: #{weight.inspect}" unless ICON_WEIGHTS.include?(weight)
    raise ArgumentError, "icon size must be one of #{ICON_SIZES.join(', ')}" unless ICON_SIZES.include?(size)
    raise ArgumentError, "unknown icon set: #{set.inspect}" unless %i[phosphor nd].include?(set)

    svg = ICON_CACHE.compute_if_absent([ set, weight, name ]) do
      path = set == :nd ? ND_ICON_ROOT.join("#{name}.svg") : ICON_ROOT.join(weight, "#{name}.svg")
      raise ArgumentError, "no icon named #{name.inspect} at #{path.dirname}" unless path.file?
      path.read.strip
    end

    classes = [ "nd-ic", ("nd-ic--#{size}" unless size == 16), options[:class] ].compact.join(" ")
    a11y = label ? %(role="img" aria-label="#{ERB::Util.html_escape(label)}") : %(aria-hidden="true")
    svg.sub("<svg ", %(<svg class="#{ERB::Util.html_escape(classes)}" #{a11y} focusable="false" )).html_safe # rubocop:disable Rails/OutputSafety
  end
end
