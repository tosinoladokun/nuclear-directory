# Homepage B's chart cards (#909).
module HomeHelper
  # The value axis for values up to max, ticks every step: [the axis's end, [0, step, 2 step, ...]]. The axis always
  # reaches past the longest bar, or to it when it lands on a tick.
  def chart_axis(max, step)
    step = step.to_f
    top = [ (max.to_f / step).ceil, 1 ].max * step
    [ top, (0..(top / step).round).map { |i| (i * step).then { |value| value == value.to_i ? value.to_i : value } } ]
  end

  # A tick step for a count axis of values up to max: the smallest of 1, 2, 5, 10, 20, 50... that needs at most 4 steps.
  def chart_step(max)
    [ 1, 2, 5 ].product([ 1, 10, 100, 1000 ]).map { |a, b| a * b }.sort.find { |step| max.to_f / step <= 4 } || 10_000
  end

  # A position or length on an axis that ends at top, as a percentage.
  def chart_pct_of(value, top) = top.to_f.positive? ? (100.0 * value / top).round(2) : 0

  # The number beside a bar: 11.6, or 11 for counts.
  def chart_value(value, decimals) = number_with_precision(value, precision: decimals, delimiter: ",")
end
