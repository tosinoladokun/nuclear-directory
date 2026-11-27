# Where everything on a connections map sits on desktop (#363, #561, #682): the page's own record in the middle with its
# name under it; what it does to others on the right, what others do to it on the left, as straight lines at right angles.
# Each side has one trunk from the record's square to a vertical bus; from the bus a straight branch runs to each
# company's square (an arrowhead on the right side's branches; on the left side the trunk's arrowhead points into the
# record). Each group has its heading (mono, muted) above its rows, so no word ever sits on a line. Group order is the
# phone tree's, so both widths read the same. Phones don't use this: they get a tree (shared/_connections_tree).
#
# The server works out every position; connections_map_controller.js then fits the names to their slots and crops the
# drawing to what it draws, so the record and its branches sit centred under the heading as one unit (#995). A side with
# no connections takes no room, and each side's names get the room the 696px column has.
#
#   layout = ConnectionsMap::Layout.new(map.folded, centre: map.centre, size: ConnectionsMap::Layout::WIDE, prefix: "cm-f-w")
#   layout.headings.map(&:text) # => ["SUPPLIED BY", "FUNDED BY", ...]
class ConnectionsMap
  class Layout
    # font and floor: a name's size and the smallest it shrinks to (the one-line law, DESIGN.md: 13px); slot: the widest a
    # name may be. centre_r and node_r are half the side of the boxes: a 36px square for the page's record, 28px for the
    # others. The map is at most 696px wide, the page's middle column; narrower when it draws less (#995).
    Size = Data.define(:key, :width, :centre_r, :node_r, :font, :floor, :slot)
    WIDE = Size.new(key: "wide", width: 696, centre_r: 18, node_r: 14, font: 15, floor: 13, slot: 148)

    PAD_X = 4
    NAME_GAP = 8      # a square to its name
    PAD_Y = 16
    ROW = 40          # one company to the next
    HEAD = 26         # a group's heading
    BRANCH = 16       # bus to a company's square
    TRUNK_MIN = 64    # the record's square to its bus, at least; longer when the record's name needs it
    NAME_CLEAR = 12   # the record's name to a bus
    SLOT_MIN = 70
    NAME_CHAR = 7.4   # a name's width per character at 13px (the floor); the controller measures the real one
    CENTRE_CHAR = 8.3 # the record's name, semibold
    CENTRE_FONT = 16

    # A node where it's drawn. anchor: the name's text-anchor. font: its size before it shrinks.
    # side: :left or :right (nil for the record), so the controller can give a column's names one size.
    Placed = Data.define(:node, :x, :y, :r, :name, :name_x, :name_y, :anchor, :slot, :font, :side)
    # One straight line (a move and horizontal or vertical runs). arrow: it ends in an arrowhead.
    Line = Data.define(:path, :arrow)
    # A group's heading above its rows.
    # The group heading on both widths: the verb, passive when the record receives it, in capitals.
    def self.heading_text(verb, inbound) = (inbound ? ConnectionsMapHelper::PASSIVE.fetch(verb) : verb).upcase

    Heading = Data.define(:text, :x, :y, :anchor)

    attr_reader :size, :prefix, :width, :height, :centre, :placed, :lines, :headings, :bus_x

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

    def nodes = placed.values

    private
      def other(edge, inbound) = inbound ? edge.giver : edge.receiver

      def lay_out(sides)
        r = size.node_r
        big = size.centre_r
        used = sides.reject { |_, list| list.empty? }.keys
        name_half = @centre_node.name.length * CENTRE_CHAR / 2.0
        # From the record's centre to each bus: a trunk of TRUNK_MIN at least, and far enough that the bus clears the
        # record's name under it. A side with no rows has no trunk or bus: the record (or its name) is that side's edge.
        reach = [ big + TRUNK_MIN, name_half + NAME_CLEAR ].max
        own = [ big, name_half ].max + PAD_X
        slots = side_slots(sides, used, reach, own)
        extent = %i[left right].to_h { |side| [ side, used.include?(side) ? reach + BRANCH + 2 * r + NAME_GAP + slots[side] + PAD_X : own ] }
        @width = (extent[:left] + extent[:right]).ceil
        cx = extent[:left]
        @bus_x = used.to_h { |side| [ side, side == :left ? cx - reach : cx + reach ] }
        bus_x = @bus_x
        node_x = { left: cx - reach - BRANCH - r, right: cx + reach + BRANCH + r }

        side_height = sides.transform_values { |list| list.sum { |(_, _, edges)| HEAD + ROW * edges.size } }
        tallest = [ side_height.values.max, 96 ].max
        cy = PAD_Y + HEAD / 2.0 + tallest / 2.0
        @height = [ cy + big + 62, cy + tallest / 2.0 + HEAD / 2.0 + PAD_Y ].max.ceil
        # The record's name: between the buses, or out to the drawing's edge on a side with none.
        middle = 2 * %i[left right].map { |side| used.include?(side) ? reach - 4 : own - PAD_X }.min
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
            @headings << Heading.new(text: Layout.heading_text(verb, inbound), x: (node_x[side] - sign * r).round(1), y: (y + HEAD - 9).round(1), anchor: side == :left ? "end" : "start")
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

      def name_estimate(edge, node)
        text = node.fold? ? row_name(edge, node) : (node.short_name.presence || node.name)
        text.length * NAME_CHAR + 12
      end

      # A fold's row says how many of its plants this verb covers ("2 of 13 plants").
      def row_name(edge, node)
        return node.name unless node.fold? && edge.covers && edge.covers < node.members.size

        "#{edge.covers} of #{node.name}"
      end

      # How wide each side's names may be. Each column first gets what its names are likely to need (the controller
      # measures the real width), then grows into what's left of the 696px, up to the cap, so no name shrinks while the
      # column has room (#995). Only when both sides need more than there is does the estimate split the room.
      def side_slots(sides, used, reach, own)
        cap = size.slot + 90
        needs = used.to_h do |side|
          # A company with a short name is given room for that (the controller still shows the full name where it fits).
          [ side, sides[side].flat_map { |(_, inbound, edges)| edges.map { |edge| name_estimate(edge, other(edge, inbound)) } }.max.to_i.clamp(SLOT_MIN, cap) ]
        end
        return needs if needs.empty?

        fixed = %i[left right].sum { |side| used.include?(side) ? reach + BRANCH + 2 * size.node_r + NAME_GAP + PAD_X : own }
        room = size.width - fixed
        total = needs.values.sum
        return needs.transform_values { |need| [ (need * room / total.to_f).floor, SLOT_MIN ].max } if total > room

        # The spare room goes first to the columns whose full names need more at full size, in proportion; then what's
        # left is shared evenly, each up to the cap.
        wants = used.to_h do |side|
          [ side, sides[side].flat_map { |(_, inbound, edges)| edges.map { |edge| full_estimate(edge, other(edge, inbound)) } }.max.to_i.clamp(needs[side], cap) ]
        end
        spare = room - total
        short = wants.sum { |side, want| want - needs[side] }
        slots = needs.to_h { |side, need| [ side, short.zero? ? need : need + [ (wants[side] - need) * spare / short.to_f, wants[side] - need ].min ] }
        2.times do
          open = slots.select { |_, slot| slot < cap }
          break if open.empty?

          share = (room - slots.values.sum) / open.size.to_f
          open.each_key { |side| slots[side] = [ slots[side] + share, cap ].min }
        end
        slots.transform_values(&:floor)
      end

      # A name's width at full size, the full name (not the short one).
      def full_estimate(edge, node) = row_name(edge, node).length * NAME_CHAR * size.font / size.floor + 12

      def place(node, x, y, r, name:, name_x:, name_y:, anchor:, slot:, font:, side: nil)
        @placed[side ? "#{node.key}@#{side}" : node.key] = Placed.new(node:, x: x.round(1), y: y.round(1), r:, name:, name_x: name_x.round(1), name_y: name_y.round(1),
          anchor:, slot: slot.round, font:, side:)
      end
  end
end
