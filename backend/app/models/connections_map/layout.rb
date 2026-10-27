# Where everything on a connections map sits (#363, Design's boards): the
# page's own record in the centre, the others grouped by verb and direction.
# Wide maps put the groups in columns left and right; narrow (phone) maps
# put them in rows above and below. Arrows that share a verb and a
# direction (two or more) merge into a bundle: each member curves into a
# junction and one trunk carries the single label.
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
    # one-line law: 13px, 12px on phones); slot: the widest a name may be.
    Size = Data.define(:key, :width, :centre_r, :node_r, :font, :floor, :label_font, :slot, :short_names)
    WIDE = Size.new(key: "wide", width: 940, centre_r: 40, node_r: 24, font: 13, floor: 13, label_font: 13, slot: 180, short_names: false)
    NARROW = Size.new(key: "narrow", width: 358, centre_r: 34, node_r: 22, font: 12, floor: 12, label_font: 12, slot: 84, short_names: true)

    PAD = 24
    ROW = 60         # wide: one node to the next in a column
    GROUP_GAP = 28   # wide: between groups in a column
    NARROW_ROW = 84  # narrow: one row of nodes to the next
    PER_ROW = 3      # narrow: nodes in a row at most (2 when names are long)
    BAND = 112       # narrow: a row's node centre to the centre's edge

    # A node where it's drawn. anchor: the name's text-anchor.
    Placed = Data.define(:node, :x, :y, :r, :name, :name_x, :name_y, :anchor, :slot)

    # One arrow of a group: its curve, and the path its dot runs (its branch,
    # then the trunk, in the direction of flow).
    Member = Data.define(:edge, :path, :dot_path, :arrow)

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
      size.key == "wide" ? lay_out_wide(groups) : lay_out_narrow(groups)
    end

    def width = size.width
    def nodes = placed.values

    # The estimated width of a word in the label font (small caps, .06em
    # tracking); the controller measures the real one.
    def self.label_width(text, font) = (text.length * font * 0.6).ceil

    private
      def other(edge, inbound) = inbound ? edge.giver : edge.receiver

      # Columns: givers to the centre prefer the left, receivers the right,
      # and a group moves across when its side is already much taller.
      def lay_out_wide(groups)
        sides = { left: [], right: [] }
        height_of = ->(list) { list.sum { |(_, inbound, edges)| fresh(edges, inbound, list).size * ROW + GROUP_GAP } }
        groups.sort_by { |(_, _, edges)| -edges.size }.each do |group|
          preferred, other_side = group[1] ? %i[left right] : %i[right left]
          side = sharing(sides, group) || (height_of.(sides[preferred]) > height_of.(sides[other_side]) + group[2].size * ROW ? other_side : preferred)
          sides[side] << group
        end
        sides.each_value { |list| list.sort_by! { |(verb, inbound, _)| [ VERBS.index(verb), inbound ? 0 : 1 ] } }

        column = sides.values.map { |list| height_of.(list) - GROUP_GAP }.max.to_i
        @height = [ column, size.centre_r * 2 + 120 ].max + PAD * 2 + 20
        cx = width / 2.0
        cy = @height / 2.0 - 10
        @centre = place(@centre_node, cx, cy, size.centre_r, name_x: cx, name_y: cy + size.centre_r + 22, anchor: "middle", slot: 220)

        r = size.node_r
        left_x = PAD + size.slot + 10 + r
        right_x = width - left_x
        sides.each do |side, list|
          y = (@height - (height_of.(list) - GROUP_GAP)) / 2.0 + ROW / 2.0 - 10
          x = side == :left ? left_x : right_x
          list.each do |verb, inbound, edges|
            nodes = edges.map do |edge|
              node = other(edge, inbound)
              next @placed[node.key] if @placed[node.key] # linked by another verb too: drawn once

              placed = place(node, x, y, r, name_x: side == :left ? x - r - 10 : x + r + 10, name_y: y + 4.5,
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
          return group(verb, inbound, edges, [ Member.new(edge: edges.first, path:, dot_path: path, arrow: true) ], nil, path)
        end

        space = (cx - big) - (PAD + size.slot + 10 + size.node_r * 2)
        trunk_length = [ [ Layout.label_width(verb, size.label_font) + 28, 88 ].max, space - 40 ].min
        mean = nodes.sum(&:y) / nodes.size
        # A second bundle to the same nodes (owns and operates the same plants)
        # meets at its own junction, lower down, so neither hides the other.
        again = reuse(nodes)
        junction = [ cx + sign * (big + trunk_length), mean + again * 48 ]
        centre_edge = towards([ cx, cy ], junction, big)
        trunk = inbound ? s_curve(junction, shorten(centre_edge, junction), push: 7) : s_curve(centre_edge, junction, push: 7)
        members = edges.zip(nodes).map do |edge, node|
          start = [ node.x - sign * node.r, node.y ]
          if inbound
            branch = elbow(start, junction)
            Member.new(edge:, path: branch, dot_path: join(branch, trunk), arrow: false)
          else
            branch = elbow(junction, shorten(start, junction))
            Member.new(edge:, path: branch, dot_path: join(trunk, branch), arrow: true)
          end
        end
        group(verb, inbound, edges, members, trunk, trunk)
      end

      # Rows: givers above (flowing down into the centre), receivers below.
      def lay_out_narrow(groups)
        bands = { top: [], bottom: [] }
        count_of = ->(list) { list.sum { |(_, inbound, edges)| fresh(edges, inbound, list).size } }
        rows_of = ->(list) { narrow_rows(names_of(list)).size }
        # The biggest group takes its own side (givers above); the rest go
        # where there are fewer nodes, so both rows stay short.
        groups.sort_by { |(_, _, edges)| -edges.size }.each_with_index do |group, index|
          preferred, other_band = group[1] ? %i[top bottom] : %i[bottom top]
          band = sharing(bands, group) || (index.zero? || count_of.(bands[preferred]) <= count_of.(bands[other_band]) ? preferred : other_band)
          bands[band] << group
        end
        bands.each_value { |list| list.sort_by! { |(verb, inbound, _)| [ VERBS.index(verb), inbound ? 0 : 1 ] } }

        r, big = size.node_r, size.centre_r
        top_rows, bottom_rows = rows_of.(bands[:top]), rows_of.(bands[:bottom])
        top = PAD + 18 + r
        cy = top_rows.zero? ? PAD + big + 8 : top + (top_rows - 1) * NARROW_ROW + r + BAND + big
        cx = width / 2.0
        @height = (bottom_rows.zero? ? cy + big + 24 : cy + big + BAND + r + (bottom_rows - 1) * NARROW_ROW + r + 20) + PAD
        @centre = place(@centre_node, cx, cy, big, name_x: cx + big + 8, name_y: cy + 4.5, anchor: "start", slot: width - cx - big - 12)

        { top: bands[:top], bottom: bands[:bottom] }.each do |band, list|
          spots = narrow_spots(names_of(list), band, top, cy)
          list.each do |verb, inbound, edges|
            nodes = edges.map do |edge|
              node = other(edge, inbound)
              next @placed[node.key] if @placed[node.key]

              x, y, slot = spots.shift
              place(node, x, y, r, name_x: x, name_y: band == :top ? y - r - 8 : y + r + 16, anchor: "middle", slot:)
            end
            @groups << narrow_group(verb, inbound, edges, nodes, band)
          end
        end
      end

      # The names a band will show, in order, each node once.
      def names_of(list)
        list.flat_map { |(_, inbound, edges)| edges.map { |edge| other(edge, inbound) } }.uniq(&:key)
          .map { |node| size.short_names && node.short_name ? node.short_name : node.name }
      end

      # How many nodes each row of a band holds, nearest the centre first:
      # three to a row when every name fits a third of the width, else two;
      # every other row holds one fewer and sits in the gaps, so a line from
      # a far row passes between the nodes of a near one.
      def narrow_rows(names)
        return [] if names.empty?

        per = names.all? { |name| name.length * size.font * 0.66 <= width / 3.0 - 8 } ? 3 : 2
        rows = []
        left = names.size
        while left.positive?
          take = [ rows.size.odd? ? per - 1 : per, left ].min
          rows << take
          left -= take
        end
        rows
      end

      # Node centres for a band, nearest row to the centre first, with each name's slot.
      def narrow_spots(names, band, top, cy)
        rows = narrow_rows(names)
        per = rows.first.to_i
        column = width / per.to_f
        rows.each_with_index.flat_map do |count, row|
          offset = row.odd? ? column / 2 : 0
          y = band == :top ? top + (rows.size - 1 - row) * NARROW_ROW : cy + size.centre_r + BAND + size.node_r + row * NARROW_ROW
          # A short row takes its row's places nearest the middle.
          places = Array.new(row.odd? ? per - 1 : per) { |index| offset + column / 2 + index * column }
          places.sort_by { |x| [ (x - width / 2.0).abs, x ] }.first(count).sort.map { |x| [ x, y, column - 8 ] }
        end
      end

      def narrow_group(verb, inbound, edges, nodes, band)
        sign = band == :top ? -1 : 1
        if edges.size == 1
          path = single(nodes.first, inbound)
          return group(verb, inbound, edges, [ Member.new(edge: edges.first, path:, dot_path: path, arrow: true) ], nil, path)
        end

        cx, cy, big = @centre.x, @centre.y, size.centre_r
        mean = nodes.sum(&:x) / nodes.size
        again = reuse(nodes)
        junction = [ cx + (mean - cx) * 0.4 + again * 64, cy + sign * (big + 52 + again * 18) ]
        centre_edge = towards([ cx, cy ], junction, big)
        trunk = inbound ? s_curve(junction, shorten(centre_edge, junction), push: 6) : s_curve(centre_edge, junction, push: 6)
        members = edges.zip(nodes).map do |edge, node|
          start = [ node.x, node.y - sign * node.r ]
          if inbound
            branch = elbow(start, junction, vertical: true)
            Member.new(edge:, path: branch, dot_path: join(branch, trunk), arrow: false)
          else
            branch = elbow(junction, shorten(start, junction), vertical: true)
            Member.new(edge:, path: branch, dot_path: join(trunk, branch), arrow: true)
          end
        end
        group(verb, inbound, edges, members, trunk, trunk)
      end

      # One arrow between the centre and a node. A node linked by two verbs
      # (owns and operates) gets two arrows bowed apart, so neither hides the other.
      def single(node, inbound)
        @bows ||= Hash.new(0)
        step = size.key == "wide" ? 30 : 52
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

      # The side a group goes on when one of its nodes is already in a group
      # there (Constellation owns two of the plants it operates), so its lines
      # don't cross the map.
      def sharing(sides, group)
        keys = group[2].map { |edge| other(edge, group[1]).key }
        sides.find { |_, list| list.any? { |(_, inbound, edges)| edges.any? { |edge| keys.include?(other(edge, inbound).key) } } }&.first
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

      def place(node, x, y, r, name_x:, name_y:, anchor:, slot:)
        name = size.short_names && node.short_name ? node.short_name : node.name
        @placed[node.key] = Placed.new(node:, x: x.round(1), y: y.round(1), r:, name:, name_x: name_x.round(1), name_y: name_y.round(1), anchor:, slot: slot.round)
      end

      # Geometry. Points are [x, y]; paths are one move and one cubic.

      # Where a line from one node toward another leaves the first's circle;
      # tip: 2px short, so the arrowhead's point touches the circle.
      def edge_point(from, to, tip: false) = towards([ from.x, from.y ], [ to.x, to.y ], from.r + (tip ? 2 : 0))

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

      # A bundle branch: leaves its node level (or upright on phones) and
      # turns into the junction.
      def elbow(from, to, vertical: false)
        if vertical
          my = (from[1] + to[1]) / 2.0
          path(from, [ from[0], my ], [ to[0], my ], to)
        else
          mx = (from[0] + to[0]) / 2.0
          path(from, [ mx, from[1] ], [ mx, to[1] ], to)
        end
      end

      def path(*points) = "M#{fmt(points[0])} C#{points[1..].map { |point| fmt(point) }.join(' ')}"
      def fmt(point) = point.map { |value| value.round(1).to_s.delete_suffix(".0") }.join(" ")
      def numbers(d) = d.scan(/-?\d+(?:\.\d+)?/).map(&:to_f)
      def join(first, second) = "#{first} #{second.sub(/\AM[^C]*/, '')}"

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
