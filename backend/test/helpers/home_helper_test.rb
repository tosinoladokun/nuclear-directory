require "test_helper"

class HomeHelperTest < ActionView::TestCase
  test "a value axis reaches the first tick at or past the longest bar, ticks every step" do
    assert_equal [ 12.0, [ 0, 4, 8, 12 ] ], chart_axis(11.6, 4)
    assert_equal [ 8.0, [ 0, 4, 8 ] ], chart_axis(8, 4), "a bar ending on a tick ends the axis"
    assert_equal [ 5.0, [ 0, 1, 2, 3, 4, 5 ] ], chart_axis(4.53, 1)
    assert_equal [ 60.0, [ 0, 20, 40, 60 ] ], chart_axis(58, 20)
    assert_equal [ 2.0, [ 0, 2 ] ], chart_axis(0, 2), "an empty chart still has an axis"
  end

  test "a count axis takes 1, 2, 5, 10, 20... so it needs at most four steps" do
    assert_equal 1, chart_step(4)
    assert_equal 2, chart_step(7)
    assert_equal 10, chart_step(38)
    assert_equal 20, chart_step(63)
  end

  test "positions and values" do
    assert_equal 50.0, chart_pct_of(4, 8)
    assert_equal 0, chart_pct_of(1, 0)
    assert_equal "11.6", chart_value(11.5956, 1)
    assert_equal "1,164", chart_value(1164, 0)
  end
end
