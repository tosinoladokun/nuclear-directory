# Where everything on a connections map sits (#363, #561): the page's own
# record in the centre, the others grouped by verb and direction, givers in
# a column on the left and receivers on the right. Arrows that share a verb
# and a direction (two or more) merge into a bundle: each member curves into
# a junction and one trunk carries the single label. Phones don't use this:
# they get a tree (shared/_connections_tree), which needs no layout.
#
# The server works out every position, so the map reads without
# JavaScript; connections_map_controller.js then fits the names and moves
# any label that collides.
#
#   layout = ConnectionsMap::Layout.new(map.folded, centre: map.centre, size: ConnectionsMap::Layout::WIDE, prefix: "cm-f-w")
#   layout.groups.first.label_path # => "M ..."
class ConnectionsMap
  class Layout
    # font and floor: a name's size and the smallest it shrinks to (DESIGN.md
    # one-line law: 13px); slot: the widest a name may be. centre_r and node_r
    # are half the side of the boxes: a 36px square for the page's record, 28px
    # for the others (#561). The map is 696px wide, the page's middle column.
    Size = Data.define(:key, :width, :centre_r, :node_r, :font, :floor, :label_font, :slot, :short_names)
    WIDE = Size.new(key: "wide", width: 696, centre_r: 18, node_r: 14, font: 13, floor: 13, label_font: 12, slot: 126, short_names: false)

    PAD = 24
    PAD_X = 8        # the left and right edge of the map to the names: the page's column has no spare room
    ROW = 48         # one node to the next in a column
    GROUP_GAP = 28   # wide: between groups in a column

    # A node where it's drawn. anchor: the name's text-anchor.
    Placed = Data.define(:node, :x, :y, :r, :name, :name_x, :name_y, :anchor, :slot)

    # One arrow of a group: its curve.
    Member = Data.define(:edge, :path, :arrow)

    # A focusable line: one edge, or a bundle. label_path: the trunk (or the
    # edge) the verb sits on; label_reversed: the same, drawn the other way,
    # so the word never reads upside down.
    Group = Data.define(:id, :verb, :edges, :inbound, :members, :trunk, :label_path, :label_reversed, :label_at, :steep) do
      def bundle? = edges.size > 1
    end

    attr_reader :size, :prefix, :height, :centre, :placed, :groups

    def initialize(edges, centre:, size:, prefix:)
      @size = size
      @prefix = prefix
      @centre_node = centre
      @placed = {}
      @groups = []
      @links_to = edges.flat_map { |edge| [ edge.giver.key, edge.receiver.key ] }.tally
      groups = edges.group_by { |edge| [ edge.verb, edge.receiver.key == centre.key ] }
        .sort_by { |(verb, inbound), list| [ VERBS.index(verb), inbound ? 0 : 1, -list.size ] }
        .map { |(verb, inbound), list| [ verb, inbound, list.sort_by { |edge| other(edge, inbound).name.downcase } ] }
      lay_out_wide(groups)
    end

    def width = size.width
    def nodes = placed.values

    # The estimated width of a word in the label font (small caps, .06em
    # tracking); the controller measures the real one.
    def self.label_width(text, font) = (text.length * font * 0.6).ceil

    private
      def other(edge, inbound) = inbound ? edge.giver : edge.receiver
      def side_key(node, side) = "#{node.key}@#{side}"

      # Columns: givers to the centre on the left, receivers on the right, always (#561). A partner that is both
      # (funds the centre and buys its power) is drawn once on each side.
      def lay_out_wide(groups)
        sides = { left: [], right: [] }
        height_of = ->(list) { list.sum { |(_, inbound, edges)| fresh(edges, inbound, list).size * ROW + GROUP_GAP } }
        groups.each { |group| sides[group[1] ? :left : :right] << group }
        sides.each_value { |list| list.sort_by! { |(verb, inbound, _)| [ VERBS.index(verb), inbound ? 0 : 1 ] } }

        column = sides.values.map { |list| height_of.(list) - GROUP_GAP }.max.to_i
        @height = [ column, size.centre_r * 2 + 120 ].max + PAD * 2 + 20
        cx = width / 2.0
        cy = @height / 2.0 - 10
        @centre = place(@centre_node, cx, cy, size.centre_r, name_x: cx, name_y: cy + size.centre_r + 30, anchor: "middle", slot: 240)

        r = size.node_r
        left_x = PAD_X + size.slot + 10 + r
        right_x = width - left_x
        sides.each do |side, list|
          y = (@height - (height_of.(list) - GROUP_GAP)) / 2.0 + ROW / 2.0 - 10
          x = side == :left ? left_x : right_x
          list.each do |verb, inbound, edges|
            nodes = edges.map do |edge|
              node = other(edge, inbound)
              next @placed[side_key(node, side)] if @placed[side_key(node, side)] # linked by another verb on this side too: drawn once

              placed = place(node, x, y, r, side:, name_x: side == :left ? x - r - 10 : x + r + 10, name_y: y + 4.5,
                anchor: side == :left ? "end" : "start", slot: size.slot)
              y += ROW
              placed
            end
            y += GROUP_GAP
            @groups << wide_group(verb, inbound, edges, nodes, side)
          end
        end
      end

      def wide_group(verb, inbound, edges, nodes, side)
        sign = side == :left ? -1 : 1
        cx, cy, big = @centre.x, @centre.y, size.centre_r
        if edges.size == 1
          path = single(nodes.first, inbound)
          return group(verb, inbound, edges, [ Member.new(edge: edges.first, path:, arrow: true) ], nil, path)
        end

        space = (cx - big) - (PAD_X + size.slot + 10 + size.node_r * 2)
        trunk_length = [ [ Layout.label_width(verb, size.label_font) + 28, 88 ].max, space - 40 ].min
        mean = nodes.sum(&:y) / nodes.size
        # A second bundle to the same nodes (owns and operates the same plants)
        # meets at its own junction, lower down, so neither hides the other.
        again = reuse(nodes)
        junction = [ cx + sign * (big + trunk_length), mean + again * 40 ]
        centre_edge = box_edge([ cx, cy ], junction, big)
        trunk = inbound ? s_curve(junction, shorten(centre_edge, junction), push: 7) : s_curve(centre_edge, junction, push: 7)
        members = edges.zip(nodes).map do |edge, node|
          start = [ node.x - sign * node.r, node.y ]
          if inbound
            branch = elbow(start, junction)
            Member.new(edge:, path: branch, arrow: false)
          else
            branch = elbow(junction, shorten(start, junction))
            Member.new(edge:, path: branch, arrow: true)
          end
        end
        group(verb, inbound, edges, members, trunk, trunk)
      end

      # One arrow between the centre and a node. A node linked by two verbs
      # (owns and operates) gets two arrows bowed apart, so neither hides the other.
      def single(node, inbound)
        @bows ||= Hash.new(0)
        step = 30
        bows = @links_to[node.node.key].even? ? [ -step, step, -step * 1.5, step * 1.5 ] : [ nil, -step, step, -step * 1.5, step * 1.5 ]
        bow = bows[@bows[node.node.key]]
        @bows[node.node.key] += 1
        from, to = inbound ? [ node, @centre ] : [ @centre, node ]
        bow = -bow if bow && !inbound # the same side of the line whichever way it runs
        s_curve(edge_point(from, to), edge_point(to, from, tip: true), push: bow)
      end

      # How many bundles already met these same nodes.
      def reuse(nodes)
        @junctions ||= Hash.new(0)
        key = nodes.map { |node| node.node.key }.sort
        (@junctions[key] += 1) - 1
      end

      # The nodes of a group not already placed by an earlier group in the list.
      def fresh(edges, inbound, list)
        earlier = list.take_while { |(_, _, other)| !other.equal?(edges) }.flat_map { |(_, was_inbound, other)| other.map { |edge| other(edge, was_inbound).key } }
        edges.map { |edge| other(edge, inbound).key }.uniq - earlier
      end

      def group(verb, inbound, edges, members, trunk, label_on)
        points = numbers(label_on)
        start, finish = points.first(2), points.last(2)
        mid = cubic_point(points, 0.5)
        tangent = cubic_tangent(points, 0.5)
        angle = Math.atan2(tangent[1], tangent[0]).abs * 180 / Math::PI
        steep = angle > 35 && angle < 145
        Group.new(id: "#{prefix}-#{edges.first.id}", verb:, edges:, inbound:, members:, trunk:, label_path: label_on,
          label_reversed: (reverse(points) if finish[0] < start[0]), label_at: mid.map { |value| value.round(1) }, steep:)
      end

      def place(node, x, y, r, name_x:, name_y:, anchor:, slot:, side: nil)
        name = size.short_names && node.short_name ? node.short_name : node.name
        @placed[side ? side_key(node, side) : node.key] = Placed.new(node:, x: x.round(1), y: y.round(1), r:, name:, name_x: name_x.round(1), name_y: name_y.round(1), anchor:, slot: slot.round)
      end

      # Geometry. Points are [x, y]; paths are one move and one cubic.

      # Where a line from one node toward another leaves the first's square (r is
      # half its side); tip: 2px short, so the arrowhead's point touches the edge.
      def edge_point(from, to, tip: false) = box_edge([ from.x, from.y ], [ to.x, to.y ], from.r + (tip ? 2 : 0))

      # The point on the square of half-side `half` around `from`, on the line toward `to`.
      def box_edge(from, to, half)
        dx, dy = to[0] - from[0], to[1] - from[1]
        reach = [ dx.abs, dy.abs ].max.nonzero? || 1
        [ from[0] + dx / reach * half, from[1] + dy / reach * half ]
      end

      def towards(from, to, distance)
        dx, dy = to[0] - from[0], to[1] - from[1]
        length = Math.hypot(dx, dy).nonzero? || 1
        [ from[0] + dx / length * distance, from[1] + dy / length * distance ]
      end

      def shorten(point, from) = towards(point, from, 2)

      # A gentle S (spec section 3): control points at a third and two thirds,
      # pushed to opposite sides by min(12% of the length, 22px).
      def s_curve(from, to, push: nil)
        dx, dy = to[0] - from[0], to[1] - from[1]
        length = Math.hypot(dx, dy).nonzero? || 1
        return arc(from, to, push, dx, dy, length) if push && push.abs >= 30
        push ||= [ length * 0.12, 22 ].min
        nx, ny = -dy / length * push, dx / length * push
        c1 = [ from[0] + dx / 3 + nx, from[1] + dy / 3 + ny ]
        c2 = [ from[0] + dx * 2 / 3 - nx, from[1] + dy * 2 / 3 - ny ]
        path(from, c1, c2, to)
      end

      # A bowed arc, for a second arrow to the same node: both control points
      # on one side.
      def arc(from, to, push, dx, dy, length)
        nx, ny = -dy / length * push, dx / length * push
        path(from, [ from[0] + dx / 3 + nx, from[1] + dy / 3 + ny ], [ from[0] + dx * 2 / 3 + nx, from[1] + dy * 2 / 3 + ny ], to)
      end

      # A bundle branch: leaves its node level and turns into the junction.
      def elbow(from, to)
        mx = (from[0] + to[0]) / 2.0
        path(from, [ mx, from[1] ], [ mx, to[1] ], to)
      end

      def path(*points) = "M#{fmt(points[0])} C#{points[1..].map { |point| fmt(point) }.join(' ')}"
      def fmt(point) = point.map { |value| value.round(1).to_s.delete_suffix(".0") }.join(" ")
      def numbers(d) = d.scan(/-?\d+(?:\.\d+)?/).map(&:to_f)

      def reverse(points)
        pairs = points.each_slice(2).to_a.reverse
        path(*pairs)
      end

      def cubic_point(points, t)
        p0, p1, p2, p3 = points.each_slice(2).to_a
        2.times.map { |i| (1 - t)**3 * p0[i] + 3 * (1 - t)**2 * t * p1[i] + 3 * (1 - t) * t**2 * p2[i] + t**3 * p3[i] }
      end

      def cubic_tangent(points, t)
        p0, p1, p2, p3 = points.each_slice(2).to_a
        2.times.map { |i| 3 * (1 - t)**2 * (p1[i] - p0[i]) + 6 * (1 - t) * t * (p2[i] - p1[i]) + 3 * t**2 * (p3[i] - p2[i]) }
      end
  end
end
