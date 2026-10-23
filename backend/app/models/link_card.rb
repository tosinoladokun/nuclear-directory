# The link-preview image for a page (#245): a 1200×630 ink card with a
# category square and label, the name, an optional line under it, and a
# footer with the wordmark and the facts. Design's spec: #245, direction E.
#
#   card = LinkCard.for_plant(PlantProfile.find("plant-vogtle"))
#   card.digest  # a hash of everything drawn: the card's URL and cache key
#   card.png     # rasterized from SVG outlines by libvips; no fonts, no browser
#
# Only published facts go on a card, and a missing one is left off (never 0
# or "unknown"). Text is drawn from glyph outlines exported from the site's
# fonts (script/build_og_glyphs.py), measured with their advance widths.
class LinkCard
  WIDTH, HEIGHT = 1200, 630
  INK, PAPER, MUTED = "#121212", "#f7f7f5", "#b8b8b4"
  PAD_TOP, PAD_SIDE, PAD_BOTTOM = 56, 72, 52
  TEXT_WIDTH = WIDTH - 2 * PAD_SIDE
  NAME_SIZES = [ 190, 160, 132, 110, 92 ].freeze
  # Provisional until #184's palette (Design); each is 4.5:1 or more on INK.
  CATEGORY_COLORS = {
    "reactor-developers" => "#5b82f0", "plants" => "#f0773a", "utilities" => "#2bb3a0", "fuel" => "#e0b33c",
    "services" => "#a78bfa", "power-buyers" => "#e86fa8", "investors" => "#7cc46a", "fusion" => "#4fc3f7"
  }.freeze
  DEFAULT_SQUARES = CATEGORY_COLORS.values_at("reactor-developers", "plants", "utilities").freeze
  TAGLINE = "Who's behind the Nuclear Supply Chain" # Tosin's wording (#216), capitals included
  # Bumped when the layout changes, so every card is drawn again.
  VERSION = 1

  # squares: colours; label: the mono line beside them; name: drawn in
  # Anton; subline: the line under the name ([text, :role] or [text, :tagline]);
  # footer_left: the wordmark, or text; footer_right: the facts;
  # footer_short: a shorter first fact, drawn when footer_right's first
  # fact doesn't fit whole (the alt text keeps footer_right).
  # name_sizes: the steps tried for the name (the default card's is fixed).
  attr_reader :squares, :label, :name, :subline, :footer_left, :footer_right, :footer_short, :name_sizes

  def initialize(squares:, name:, label: nil, subline: nil, footer_left: :wordmark, footer_right: nil, footer_short: nil, name_sizes: NAME_SIZES)
    @squares, @label, @name, @subline, @footer_left, @footer_right = squares, label, name, subline, footer_left, footer_right
    @footer_short, @name_sizes = footer_short, name_sizes
  end

  def self.helpers = ApplicationController.helpers

  def self.for_plant(profile)
    type = helpers.facility_type_label(profile.facility_type)
    # "Waynesboro, GA" when a source names the town (#225); otherwise the state's full name.
    where = profile.city.present? ? helpers.place(profile.city, profile.state) : US_STATES[profile.state.to_s] || profile.state.presence
    label = [ type, where ].compact.join(" · ").presence
    reactors = %w[power_reactor research_reactor].include?(profile.facility_type.to_s)
    capacity = "#{helpers.number_with_precision(profile.capacity_mw, precision: 2, strip_insignificant_zeros: true, delimiter: ",")} MW" if profile.capacity_mw
    noun = reactors ? "reactor" : "unit"
    statuses = profile.units.map(&:status)
    facts = [ helpers.units_summary(statuses, noun:), capacity ].compact.join(" · ").presence
    # "3 reactors, 2 operating" when the statuses don't fit the image whole.
    operating = statuses.count("operating")
    short = [ helpers.pluralize(statuses.size, noun), ("#{operating} operating" if operating.positive?) ].compact.join(", ") if statuses.any?
    roles = { "Operated by" => profile.current_companies_for("operates").map(&:name), "Owned by" => profile.current_companies_for("owns").map(&:name) }
    new(squares: [ CATEGORY_COLORS["plants"] ], label:, name: profile.name, subline: roles.values.any?(&:any?) ? [ roles, :role ] : nil,
      footer_right: facts, footer_short: short)
  end

  def self.for_company(profile)
    # The role behind its first bucket ("Reactor designer", not "Molten salt
    # coolant"). A bucket it's in through its links has no such role, so the
    # bucket's own name stands in ("Power plant owners and operators"), never a role
    # from a bucket it isn't in. With no bucket, its first role.
    bucket = profile.category
    keys = bucket&.role_keys.to_a
    role = profile.shown_roles.map(&:role).find { |r| ([ r.key, r.parent&.key ] & keys).any? }
    kind = if role then helpers.role_label(role)
    elsif bucket then bucket.name
    else profile.shown_roles.first&.role&.then { |r| helpers.role_label(r) }
    end
    # Only what the page shows: HQ when a source backs the company (CompanyProfile).
    place = [ profile.hq_city.presence, profile.hq_state.presence ].compact.join(", ").presence
    label = [ kind, place ].compact.join(" · ").presence
    # Present tense, so only links in effect today (as on a plant's card).
    current = ->(link) { (link.started_on.nil? || link.started_on <= Date.current) && (link.ended_on.nil? || link.ended_on > Date.current) }
    sites = ->(type) { profile.plant_links.select { |link| link.relationship_type == type && current.call(link) }.map { |link| link.facility.parent || link.facility }.uniq.size }
    operates, owns, deals = sites.call("operates"), sites.call("owns"), profile.deals.size
    facts = [ ("Operates #{helpers.pluralize(operates, 'plant')}" if operates.positive?),
              ("Owns stakes in #{helpers.pluralize(owns, 'plant')}" if owns.positive?),
              (helpers.pluralize(deals, "deal") if deals.positive?) ].compact.first(2).join(" · ").presence
    new(squares: [ CATEGORY_COLORS[profile.category&.key] || PAPER ], label:, name: profile.name, footer_right: facts)
  end

  def self.for_category(category, count)
    noun = category.plants ? helpers.pluralize(count, "plant or site", plural: "plants and sites") : helpers.pluralize(count, "company", plural: "companies")
    new(squares: [ CATEGORY_COLORS[category.key] || PAPER ], label: "Category", name: category.name, footer_right: noun)
  end

  def self.default
    new(squares: DEFAULT_SQUARES, name: "Nuclear Directory", subline: [ TAGLINE, :tagline ], name_sizes: [ 170 ],
      footer_left: "Companies · plants and sites · deals", footer_right: "nuclear-directory.org")
  end

  def to_h = { v: VERSION, squares:, label:, name:, subline:, footer_left:, footer_right:, footer_short:, name_sizes: }

  def digest = @digest ||= Digest::SHA256.hexdigest(to_h.to_json)[0, 16]

  # "Plant Vogtle: Power plant · Georgia. 4 reactors · 4,530 MW." The default card uses its tagline.
  def alt
    return TAGLINE if subline&.last == :tagline

    # Every name, as alt text isn't cut to a width.
    roles = subline.first.select { |_, names| names.any? }.map { |role, names| "#{role} #{names.to_sentence(last_word_connector: ' and ')}" }.join(" · ") if subline&.last == :role
    [ [ name, label ].compact.join(": "), roles, footer_right ].compact_blank.map { |part| part.end_with?(".") ? part : "#{part}." }.join(" ")
  end

  def png
    require "vips"
    # Active Storage blocks libvips's untrusted loaders, SVG among them, for
    # uploads. This SVG is drawn here from our own glyphs, so only the
    # in-memory SVG loader is allowed again; file loaders stay blocked.
    Vips.block("VipsForeignLoadSvgBuffer", false)
    Vips::Image.svgload_buffer(svg).write_to_buffer(".png", compression: 9)
  end

  def svg
    parts = [ %(<rect width="#{WIDTH}" height="#{HEIGHT}" fill="#{INK}"/>) ]
    draw_label(parts)
    draw_middle(parts)
    draw_footer(parts)
    %(<svg xmlns="http://www.w3.org/2000/svg" width="#{WIDTH}" height="#{HEIGHT}" viewBox="0 0 #{WIDTH} #{HEIGHT}">#{parts.join}</svg>)
  end

  # The role line as drawn: as many names as fit, then "+N".
  def role_text
    return unless subline&.last == :role

    @role_text ||= fit_roles(subline.first)
  end

  private
    LABEL = { font: :mono_medium, size: 26, tracking: 0.06 }.freeze
    ROLE = { font: :mono, size: 28 }.freeze
    TAGLINE_FONT = { font: :serif, size: 36 }.freeze
    WORDMARK = { font: :anton, size: 34, tracking: 0.02 }.freeze
    FACTS = { font: :mono, size: 30 }.freeze
    LABEL_TOP = PAD_TOP
    FOOTER_HEIGHT = 44 # the row under the hairline
    FOOTER_GAP = 48 # at least, between its left and right
    MIDDLE_MARGIN = 24 # at least, above the name and above the hairline
    FOOTER_RULE_Y = HEIGHT - PAD_BOTTOM - FOOTER_HEIGHT - 20 - 2

    # The squares alone (26), or with the mono label beside them.
    def label_height = label ? 34 : 26

    # The role line or tagline under the name, with its 20px gap; 0 without one.
    def subline_height
      return 0 unless subline

      20 + (subline.last == :role ? ROLE : TAGLINE_FONT)[:size] * 1.32
    end

    def draw_label(parts)
      center = LABEL_TOP + label_height / 2.0
      x = PAD_SIDE
      squares.each do |color|
        parts << %(<rect x="#{x}" y="#{(center - 13).round(2)}" width="26" height="26" fill="#{color}"/>)
        x += 26 + 10
      end
      return unless label

      x += 16 - 10
      text = Font.fit(label.upcase, TEXT_WIDTH - (x - PAD_SIDE), **LABEL)
      parts << Font.path(text, x, Font.centered_baseline(center, **LABEL), fill: PAPER, **LABEL)
    end

    # The name, and the role line or tagline under it, centred between the
    # label and the footer, as CSS's space-between places them.
    def draw_middle(parts)
      size, lines = name_lines
      line_height = size * 0.9
      sub = subline && (subline.last == :role ? [ role_text, ROLE, MUTED ] : [ subline.first, TAGLINE_FONT, PAPER ])
      sub_height = subline_height
      block = lines.size * line_height + sub_height
      top = LABEL_TOP + label_height + (FOOTER_RULE_Y - LABEL_TOP - label_height - block) / 2.0
      lines.each_with_index do |line, i|
        center = top + line_height * (i + 0.5)
        parts << Font.path(line, PAD_SIDE, Font.centered_baseline(center, font: :anton, size:), font: :anton, size:, fill: PAPER)
      end
      return unless sub

      text, style, color = sub
      center = top + lines.size * line_height + 20 + style[:size] * 1.32 / 2
      parts << Font.path(Font.fit(text, TEXT_WIDTH, **style), PAD_SIDE, Font.centered_baseline(center, **style), fill: color, **style)
    end

    def draw_footer(parts)
      parts << %(<rect x="#{PAD_SIDE}" y="#{FOOTER_RULE_Y}" width="#{TEXT_WIDTH}" height="2" fill="#{PAPER}"/>)
      center = HEIGHT - PAD_BOTTOM - FOOTER_HEIGHT / 2.0
      left, left_style, right = footer_drawn
      parts << Font.path(left, PAD_SIDE, Font.centered_baseline(center, **left_style), fill: PAPER, **left_style)
      return unless right

      x = PAD_SIDE + TEXT_WIDTH - Font.width(right, **FACTS)
      parts << Font.path(right, x, Font.centered_baseline(center, **FACTS), fill: PAPER, **FACTS)
    end

    # [left text, its style, the facts as drawn]. Text on both sides keeps
    # 48px between them, the left at 26px if need be (Design). Whole facts
    # are dropped from the end before one is cut ("Operates 1 plant", not
    # "Operates 1 plant · Owns stakes in 2…"); a first fact too long to fit
    # whole gives way to footer_short ("3 reactors, 2 operating").
    def footer_drawn
      left_style = footer_left == :wordmark ? WORDMARK : FACTS
      left = footer_left == :wordmark ? "NUCLEAR DIRECTORY" : footer_left
      if footer_left != :wordmark && footer_right &&
          Font.width(left, **FACTS) + FOOTER_GAP + Font.width(footer_right, **FACTS) > TEXT_WIDTH
        left_style = FACTS.merge(size: 26)
      end
      return [ left, left_style, nil ] unless footer_right

      room = TEXT_WIDTH - Font.width(left, **left_style) - FOOTER_GAP
      facts = footer_right.split(" · ")
      facts[0] = footer_short if footer_short && Font.width(facts.first, **FACTS) > room
      facts.pop while facts.size > 1 && Font.width(facts.join(" · "), **FACTS) > room
      [ left, left_style, Font.fit(facts.join(" · "), room, **FACTS) ]
    end

    # The largest step at which the uppercase name fits two lines and the
    # middle band (name and the line under it) keeps MIDDLE_MARGIN above and
    # below: so a two-line name with a role line starts at 160, not 190
    # (Design). At the smallest, the second line is cut with "…".
    def name_lines
      text = name.upcase
      room = FOOTER_RULE_Y - LABEL_TOP - label_height - 2 * MIDDLE_MARGIN
      name_sizes.each do |size|
        lines = Font.wrap(text, TEXT_WIDTH, font: :anton, size:)
        return [ size, lines ] if lines && lines.size <= 2 && (lines.size * size * 0.9 + subline_height <= room || size == name_sizes.last)
      end
      size = name_sizes.last
      style = { font: :anton, size: }
      lines = Font.wrap(text, TEXT_WIDTH, hard: true, **style)
      # A word wider than a line is cut too; a single word has no second line.
      first = Font.fit(lines[0], TEXT_WIDTH, **style)
      return [ size, [ first ] ] if lines.size == 1

      [ size, [ first, Font.fit(lines[1..].join(" "), TEXT_WIDTH, force_ellipsis: lines.size > 2, **style) ] ]
    end

    # "Operated by Southern Nuclear · Owned by Georgia Power + 3": every
    # name if they fit, else fewer with the rest counted. If one name each
    # is still too long, the longest is shortened with "…"; the counts stay.
    def fit_roles(roles)
      roles = roles.select { |_, names| names.any? }.transform_values(&:dup)
      shown = roles.transform_values(&:size)
      done = []
      line = -> { roles.map { |role, names| [ "#{role} #{names.first(shown[role]).join(', ')}", ("+ #{names.size - shown[role]}" if shown[role] < names.size) ].compact.join(" ") }.join(" · ") }
      until Font.width(line.call, **ROLE) <= TEXT_WIDTH
        role = shown.select { |_, count| count > 1 }.max_by { |_, count| count }&.first
        if role
          shown[role] -= 1
        else
          # A word at a time from whichever name is longest now, each kept to
          # its first word at the least, until the whole line fits.
          longest = roles.keys.reject { |key| done.include?(key) }.max_by { |key| Font.width(roles[key].first, **ROLE) }
          # Each name down to one word and still too long: letters go,
          # from the widest name, down to one letter each.
          unless longest
            widest = roles.keys.max_by { |key| Font.width(roles[key].first, **ROLE) }
            letters = roles[widest].first.delete_suffix(Font::ELLIPSIS)
            break if letters.length <= 1

            roles[widest][0] = "#{letters[0...-1].rstrip}#{Font::ELLIPSIS}"
            next
          end

          words = roles[longest].first.delete_suffix(Font::ELLIPSIS).split
          next done << longest if words.size < 2

          roles[longest][0] = "#{words[0...-1].join(' ').sub(/[[:punct:]]+\z/, '')}#{Font::ELLIPSIS}"
        end
      end
      line.call
    end

  US_STATES = {
    "AL" => "Alabama", "AK" => "Alaska", "AZ" => "Arizona", "AR" => "Arkansas", "CA" => "California", "CO" => "Colorado",
    "CT" => "Connecticut", "DE" => "Delaware", "DC" => "District of Columbia", "FL" => "Florida", "GA" => "Georgia",
    "HI" => "Hawaii", "ID" => "Idaho", "IL" => "Illinois", "IN" => "Indiana", "IA" => "Iowa", "KS" => "Kansas",
    "KY" => "Kentucky", "LA" => "Louisiana", "ME" => "Maine", "MD" => "Maryland", "MA" => "Massachusetts",
    "MI" => "Michigan", "MN" => "Minnesota", "MS" => "Mississippi", "MO" => "Missouri", "MT" => "Montana",
    "NE" => "Nebraska", "NV" => "Nevada", "NH" => "New Hampshire", "NJ" => "New Jersey", "NM" => "New Mexico",
    "NY" => "New York", "NC" => "North Carolina", "ND" => "North Dakota", "OH" => "Ohio", "OK" => "Oklahoma",
    "OR" => "Oregon", "PA" => "Pennsylvania", "PR" => "Puerto Rico", "RI" => "Rhode Island", "SC" => "South Carolina",
    "SD" => "South Dakota", "TN" => "Tennessee", "TX" => "Texas", "UT" => "Utah", "VT" => "Vermont", "VA" => "Virginia",
    "WA" => "Washington", "WV" => "West Virginia", "WI" => "Wisconsin", "WY" => "Wyoming"
  }.freeze
end
