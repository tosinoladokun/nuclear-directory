# Drawing the connections map (#363): icons inside the SVG, the words for
# each line and the details card. The map itself is ConnectionsMap; where
# things sit is ConnectionsMap::Layout.
module ConnectionsMapHelper
  # "Georgia Power and MEAG Power own Plant Vogtle": the verb agrees with
  # several givers.
  PLURAL_VERBS = { "owns" => "own", "operates" => "operate", "supplies" => "supply", "sells power to" => "sell power to", "funds" => "fund" }.freeze

  # One of our line icons, drawn inside the map's SVG, centred on (x, y).
  def map_icon(name, x, y, size)
    inner = IconHelper::ICON_CACHE.compute_if_absent([ :nd, "regular", name ]) { IconHelper::ND_ICON_ROOT.join("#{name}.svg").read.strip }
      .sub(/\A<svg[^>]*>/, "").delete_suffix("</svg>")
    scale = size / 24.0
    tag.g(inner.html_safe, class: "nd-map__icon", transform: "translate(#{(x - size / 2.0).round(1)} #{(y - size / 2.0).round(1)}) scale(#{scale.round(3)})", # rubocop:disable Rails/OutputSafety
      fill: "none", stroke: "currentColor", "stroke-width": 2, "stroke-linecap": "round", "stroke-linejoin": "round")
  end

  def map_node_icon(map, node)
    if node.fold? then "site-plant"
    elsif node.plant? then site_icon_name(node.record.facility_type, reactor_types: [ node.record.reactor_type ].compact, status: node.record.status)
    elsif (category = map.category(node)) then "bucket-#{category.key}"
    end
  end

  def map_node_url(node)
    if node.plant? then plant_url_for(node.record)
    elsif node.company? then company_url_for(node.record)
    end
  end

  # What a screen reader hears for a line: "Southern Nuclear operates Plant
  # Vogtle"; a bundle names every giver or receiver.
  def map_group_label(group)
    others = group.edges.map { |edge| group.inbound ? edge.giver.name : edge.receiver.name }
    centre = group.inbound ? group.edges.first.receiver.name : group.edges.first.giver.name
    if group.inbound
      "#{others.to_sentence} #{others.size > 1 ? PLURAL_VERBS.fetch(group.verb) : group.verb} #{centre}"
    else
      "#{centre} #{group.verb} #{others.to_sentence}"
    end
  end

  # "Georgia Power → Plant Vogtle", or "4 companies → Plant Vogtle" for a bundle.
  def map_card_title(group)
    first = group.edges.first
    return "#{first.giver.name} → #{first.receiver.name}" unless group.bundle?

    others = group.edges.map { |edge| group.inbound ? edge.giver : edge.receiver }
    count = others.all?(&:plant?) ? pluralize(others.size, "plant") : pluralize(others.size, "company", "companies")
    group.inbound ? "#{count} → #{first.receiver.name}" : "#{first.giver.name} → #{count}"
  end

  # "georgiapower.com · checked 2026-10-12"
  def map_source_line(edge)
    [ edge.sources.map(&:domain).compact.uniq.join(", ").presence, ("checked #{edge.checked_on.iso8601}" if edge.checked_on) ].compact.join(" · ")
  end

  # The same card for the same line in every view and size.
  def map_card_key(group) = "card-#{group.verb.parameterize}-#{group.edges.map(&:id).join('-')}"

  # "Georgia Power owns Plant Vogtle: 45.7% share (georgiapower.com)"
  def map_list_item(edge)
    details = edge.details.join("; ")
    "#{edge.sentence}#{": #{details}" if details.present?} (#{edge.sources.map(&:domain).compact.uniq.join(', ')})"
  end
end
