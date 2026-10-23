require "test_helper"

# Search gaps (#483): what the site's search found nothing for, kept as the
# normalised query only, counted, and closed once it finds something.
class SearchGapTest < ActiveSupport::TestCase
  test "a miss is kept normalised and counted; a hit closes it; a later miss opens it again" do
    SearchGap.record("  Ocean   Atomics ", results: 0)
    SearchGap.record("ocean atomics", results: 0, today: Date.tomorrow)
    gap = SearchGap.sole
    assert_equal [ "ocean atomics", 2, "open", Date.current, Date.tomorrow ],
      [ gap.query, gap.searches_count, gap.status, gap.first_searched_on, gap.last_searched_on ]

    SearchGap.record("Ocean Atomics", results: 1)
    assert gap.reload.status_closed?
    SearchGap.record("ocean atomics", results: 0)
    assert_equal [ "open", 3 ], [ gap.reload.status, gap.searches_count ]
  end

  test "an email, a phone number or one or two letters isn't kept" do
    [ "me@example.com", "call 555 123 4567", "ab", " x ", "5550199", "212\u2011555\u20110199", "555\u00A0123\u00A04567", "555\u202F123\u202F4567", "#{'nuclear ' * 13}me@example.com",
      "#{'nuclear ' * 12}call 555 123 4567" ].each { |query| SearchGap.record(query, results: 0) }
    assert_equal 0, SearchGap.count
  end

  test "a decided gap keeps its decision when searched again, and a hit doesn't close it" do
    SearchGap.record("nextera", results: 0)
    gap = SearchGap.sole
    gap.decide!("covered", by: "human:tosin")
    SearchGap.record("nextera", results: 0)
    SearchGap.record("nextera", results: 3)
    assert_equal [ "covered", 2, "human:tosin" ], [ gap.reload.status, gap.searches_count, gap.decided_by ]
  end
end
