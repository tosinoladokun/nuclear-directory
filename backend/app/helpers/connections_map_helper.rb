# Drawing the connections map (#363): icons inside the SVG, the words for
# each line and the details card. The map itself is ConnectionsMap; where
# things sit is ConnectionsMap::Layout.
module ConnectionsMapHelper
  # "Georgia Power and MEAG Power own Plant Vogtle": the verb agrees with
  # several givers.
  PLURAL_VERBS = { "owns" => "own", "operates" => "operate", "supplies" => "supply", "sells power to" => "sell power to", "funds" => "fund", ConnectionsMap::BOTH => "own and operate" }.freeze

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
    elsif node.plant?
      # A site's own type and status show only once it's verified and sourced
      # (PlantProfile#site_facts?): a pending site can be public through a unit.
      site = node.record
      site.verified? && site.evidence.any? ? site_icon_name(site.facility_type, reactor_types: [ site.reactor_type ].compact, status: site.status) : "site-plant"
    elsif (category = map.category(node)) then "bucket-#{category.key}"
    end
  end

  def map_node_url(node)
    if node.plant? then plant_url_for(node.record)
    elsif node.company? then company_url_for(node.record)
    end
  end

  # What the group of connections says, built from the same data as the picture (#561):
  # "Connections. X-energy: funded by DOE; supplied by Centrus and Sargent & Lundy; sells power to Amazon; owns TRISO-X".
  PASSIVE = { "owns" => "owned by", "operates" => "operated by", "supplies" => "supplied by", "sells power to" => "buys power from", "funds" => "funded by", ConnectionsMap::BOTH => "owned and operated by" }.freeze

  # Why the map can count fewer than Deals and links (#561): early-stage deals aren't arrows.
  EARLY_STAGE = "Early-stage deals are listed under Deals and links."

  def map_summary(map)
    phrases = map.folded.group_by { |edge| [ edge.receiver.key == map.centre.key, edge.verb ] }
      .sort_by { |(inbound, verb), _| [ inbound ? 0 : 1, ConnectionsMap.verb_rank(verb) ] }
      .map do |(inbound, verb), edges|
        names = edges.map { |edge| map_partner_name(edge, inbound ? edge.giver : edge.receiver) }.to_sentence
        "#{inbound ? PASSIVE.fetch(verb) : verb} #{names}"
      end
    "Connections. #{map.centre.name}: #{phrases.join("; ")}.#{" #{EARLY_STAGE}" if map.notes.any?}"
  end

  # A partner's name, or for folded plants how many of them this verb covers ("2 of 13 plants").
  def map_partner_name(edge, node)
    return node.name unless node.fold? && edge.covers && edge.covers < node.members.size

    "#{edge.covers} of #{node.name}"
  end

  # The phone tree's rows (#561): givers first, then receivers, by verb in the spec's order.
  TREE_ORDER = { true => %w[funds supplies], false => [ "sells power to", "owns", ConnectionsMap::BOTH, "operates" ] }.freeze
  TreeRow = Struct.new(:verb, :inbound, :node, :edge, keyword_init: true)

  def map_tree_rows(map, edges = map.folded)
    edges.map do |edge|
      inbound = edge.receiver.key == map.centre.key
      TreeRow.new(verb: edge.verb, inbound:, node: (inbound ? edge.giver : edge.receiver), edge:)
    end.sort_by { |row| [ row.inbound ? 0 : 1, TREE_ORDER[row.inbound].index(row.verb) || 9, row.node.name.downcase ] }
  end
end
