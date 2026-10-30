# Where everything on a connections map sits on desktop (#363, #561, #682): the page's own record in the middle with its
# name under it; what it does to others on the right, what others do to it on the left, as straight lines at right angles.
# Each side has one trunk from the record's square to a vertical bus; from the bus a straight branch runs to each
# company's square (an arrowhead on the right side's branches; on the left side the trunk's arrowhead points into the
# record). Each group has its heading (mono, muted) above its rows, so no word ever sits on a line. Group order is the
# phone tree's, so both widths read the same. Phones don't use this: they get a tree (shared/_connections_tree).
#
# The server works out every position; connections_map_controller.js then fits the names to their slots.
#
#   layout = ConnectionsMap::Layout.new(map.folded, centre: map.centre, size: ConnectionsMap::Layout::WIDE, prefix: "cm-f-w")
#   layout.headings.map(&:text) # => ["SUPPLIED BY", "FUNDED BY", ...]
class ConnectionsMap
  class Layout
    # font and floor: a name's size and the smallest it shrinks to (the one-line law, DESIGN.md: 13px); slot: the widest a
    # name may be. centre_r and node_r are half the side of the boxes: a 36px square for the page's record, 28px for the
    # others. The map is 696px wide, the page's middle column.
    Size = Data.define(:key, :width, :centre_r, :node_r, :font, :floor, :slot)
    WIDE = Size.new(key: "wide", width: 696, centre_r: 18, node_r: 14, font: 15, floor: 13, slot: 148)

    PAD_X = 4
    NAME_GAP = 8      # a square to its name
    PAD_Y = 16
    ROW = 40          # one company to the next
    HEAD = 26         # a group's heading
    BRANCH = 16       # bus to a company's square
    TRUNK_MIN = 64    # the record's square to its bus
    SLOT_MIN = 70
    NAME_CHAR = 7.4   # a name's width per character at 13px (the floor); the controller measures the real one
    CENTRE_CHAR = 8.3 # the record's name, semibold
    CENTRE_FONT = 16

    # A node where it's drawn. anchor: the name's text-anchor. font: its size before it shrinks.
    Placed = Data.define(:node, :x, :y, :r, :name, :name_x, :name_y, :anchor, :slot, :font)
    # One straight line (a move and horizontal or vertical runs). arrow: it ends in an arrowhead.
    Line = Data.define(:path, :arrow)
    # A group's heading above its rows.
    Heading = Data.define(:text, :x, :y, :anchor)

    attr_reader :size, :prefix, :height, :centre, :placed, :lines, :headings, :bus_x

    def initialize(edges, centre:, size:, prefix:)
      @size = size
      @prefix = prefix
      @centre_node = centre
      @placed = {}
      @lines = []
      @headings = []
      groups = edges.group_by { |edge| [ edge.verb, edge.receiver.key == centre.key ] }
      sides = { left: [], right: [] }
      groups.each { |(verb, inbound), list| sides[inbound ? :left : :right] << [ verb, inbound, list.sort_by { |edge| other(edge, inbound).name.downcase } ] }
      sides.each_value { |list| list.sort_by! { |(verb, inbound, _)| [ ConnectionsMapHelper::TREE_ORDER[inbound].index(verb) || 9, ConnectionsMap.verb_rank(verb) ] } }
      lay_out(sides)
    end

    def width = size.width
    def nodes = placed.values

    private
      def other(edge, inbound) = inbound ? edge.giver : edge.receiver

      def lay_out(sides)
        r = size.node_r
        big = size.centre_r
        slots = side_slots(sides)
        node_x = { left: PAD_X + slots[:left] + NAME_GAP + r, right: width - (PAD_X + slots[:right] + NAME_GAP + r) }
        @bus_x = { left: node_x[:left] + r + BRANCH, right: node_x[:right] - r - BRANCH }
        bus_x = @bus_x
        cx = (bus_x[:left] + bus_x[:right]) / 2.0

        side_height = sides.transform_values { |list| list.sum { |(_, _, edges)| HEAD + ROW * edges.size } }
        tallest = [ side_height.values.max, 96 ].max
        cy = PAD_Y + HEAD / 2.0 + tallest / 2.0
        @height = [ cy + big + 62, cy + tallest / 2.0 + HEAD / 2.0 + PAD_Y ].max.ceil
        middle = bus_x[:right] - bus_x[:left] - 8
        @centre = place(@centre_node, cx, cy, big, name: @centre_node.name, name_x: cx, name_y: cy + big + 30, anchor: "middle", slot: middle, font: CENTRE_FONT)

        sides.each do |side, list|
          next if list.empty?

          sign = side == :left ? -1 : 1
          # The rows' middle sits level with the record, so a lone company is straight across from it.
          y = cy - side_height[side] / 2.0
          first_row = y + HEAD + ROW / 2.0
          last_row = y + side_height[side] - ROW / 2.0
          y += cy - (first_row + last_row) / 2.0
          rows = []
          list.each do |verb, inbound, edges|
            @headings << Heading.new(text: heading_text(verb, inbound), x: (node_x[side] - sign * r).round(1), y: (y + HEAD - 9).round(1), anchor: side == :left ? "end" : "start")
            y += HEAD
            edges.each do |edge|
              node = other(edge, inbound)
              place(node, node_x[side], y + ROW / 2.0, r, name: row_name(edge, node), side:, name_x: node_x[side] + sign * (r + NAME_GAP), name_y: y + ROW / 2.0 + 5,
                anchor: side == :left ? "end" : "start", slot: slots[side], font: size.font)
              rows << (y + ROW / 2.0)
              y += ROW
            end
          end
          draw_side(side, sign, bus_x[side], node_x[side], rows, cx, cy, big, r)
        end
      end

      # The trunk, the bus and a branch to each row.
      def draw_side(side, sign, bus, node_x, rows, cx, cy, big, r)
        top, bottom = [ rows.min, cy ].min, [ rows.max, cy ].max
        record_edge = cx + sign * big
        # right: out of the record, no arrowhead; left: into the record, with one.
        @lines << (side == :right ? Line.new(path: "M#{f(record_edge)} #{f(cy)}H#{f(bus)}", arrow: false) : Line.new(path: "M#{f(bus)} #{f(cy)}H#{f(record_edge - 2)}", arrow: true))
        @lines << Line.new(path: "M#{f(bus)} #{f(top)}V#{f(bottom)}", arrow: false)
        rows.each do |y|
          @lines << (side == :right ? Line.new(path: "M#{f(bus)} #{f(y)}H#{f(node_x - r - 2)}", arrow: true) : Line.new(path: "M#{f(node_x + r)} #{f(y)}H#{f(bus)}", arrow: false))
        end
      end

      def f(value) = value.round(1).to_s.delete_suffix(".0")

      # The words over a group: what the record does ("SUPPLIES") or what is done to it ("SUPPLIED BY").
      def heading_text(verb, inbound) = (inbound ? ConnectionsMapHelper::PASSIVE.fetch(verb) : verb).upcase

      def name_estimate(edge, node)
        text = node.fold? ? row_name(edge, node) : (node.short_name.presence || node.name)
        text.length * NAME_CHAR + 12
      end

      # A fold's row says how many of its plants this verb covers ("2 of 13 plants").
      def row_name(edge, node)
        return node.name unless node.fold? && edge.covers && edge.covers < node.members.size

        "#{edge.covers} of #{node.name}"
      end

      # How wide each side's names are likely to be, so each column reserves what its names need and the rest stays in
      # the middle for the trunks and the record's name (the controller measures the real width).
      def side_slots(sides)
        needs = sides.transform_values do |list|
          # A company with a short name is given room for that (the controller still shows the full name where it fits).
          list.flat_map { |(_, inbound, edges)| edges.map { |edge| name_estimate(edge, other(edge, inbound)) } }.max.to_i.clamp(SLOT_MIN, size.slot + 90)
        end
        # The middle keeps room for the record's name at 13px (and the trunks at least TRUNK_MIN each side); the two
        # slots share what is left.
        middle = [ @centre_node.name.length * CENTRE_CHAR + 8, size.centre_r * 2 + 2 * TRUNK_MIN ].max
        room = width - 2 * (PAD_X + NAME_GAP + 2 * size.node_r + BRANCH) - middle
        total = needs.values.sum
        return needs.transform_values(&:round) if total <= room

        needs.transform_values { |need| [ (need * room / total.to_f).round, SLOT_MIN ].max }
      end

      def place(node, x, y, r, name:, name_x:, name_y:, anchor:, slot:, font:, side: nil)
        @placed[side ? "#{node.key}@#{side}" : node.key] = Placed.new(node:, x: x.round(1), y: y.round(1), r:, name:, name_x: name_x.round(1), name_y: name_y.round(1),
          anchor:, slot: slot.round, font:)
      end
  end
end
