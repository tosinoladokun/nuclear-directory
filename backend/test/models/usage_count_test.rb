require "test_helper"

class UsageCountTest < ActiveSupport::TestCase
  test "page views are counted per path per day" do
    3.times { UsageCount.track_page_view("/companies/terrapower") }
    UsageCount.track_page_view("/companies/terrapower", day: Date.yesterday)

    assert_equal 3, UsageCount.page_view.find_by!(day: Date.current, key: "/companies/terrapower").count
    assert_equal 2, UsageCount.count
  end

  test "searches are normalized so spellings of the same query count together" do
    UsageCount.track_search("TerraPower ", results: 1)
    UsageCount.track_search("  terrapower", results: 1)

    assert_equal [ [ "terrapower", 2 ] ], UsageCount.top(:search, since: Date.current)
  end

  test "searches that find nothing are counted separately" do
    UsageCount.track_search("sodium supplier", results: 0)
    UsageCount.track_search("TerraPower", results: 3)

    assert_equal [ [ "sodium supplier", 1 ] ], UsageCount.top(:search_no_results, since: Date.current)
    assert_equal 2, UsageCount.search.sum(:count)
  end

  test "blank searches aren't counted" do
    UsageCount.track_search("   ", results: 0)
    UsageCount.track_search(nil, results: 0)

    assert_equal 0, UsageCount.count
  end

  test "keys are capped in length" do
    UsageCount.track_search("x" * 500, results: 0)
    assert_equal UsageCount::MAX_KEY_LENGTH, UsageCount.search.sole.key.length
  end

  test "top sums across days and sorts by count" do
    UsageCount.track_page_view("/a", day: Date.yesterday)
    UsageCount.track_page_view("/a")
    UsageCount.track_page_view("/b")

    assert_equal [ [ "/a", 2 ], [ "/b", 1 ] ], UsageCount.top(:page_view, since: Date.yesterday)
    assert_equal [ [ "/a", 1 ], [ "/b", 1 ] ], UsageCount.top(:page_view, since: Date.current)
  end

  test "event must be a known value" do
    assert_not UsageCount.new(day: Date.current, event: "click", key: "/").valid?
  end
end
