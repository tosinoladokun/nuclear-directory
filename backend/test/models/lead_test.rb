require "test_helper"

class LeadTest < ActiveSupport::TestCase
  test "one lead per kind and name, however it's written; each source counted once, updated in place" do
    Lead.sighted!(name: "Example Fusion", kind: "company", key: "search:1", label: "Search", times: 3, first: Date.new(2026, 10, 1), last: Date.new(2026, 10, 5))
    Lead.sighted!(name: "EXAMPLE  fusion.", kind: "company", key: "news:9", label: "News", first: Date.new(2026, 10, 7))
    lead = Lead.sole
    assert_equal [ "Example Fusion", 4, Date.new(2026, 10, 1), Date.new(2026, 10, 7) ], [ lead.name, lead.seen_count, lead.first_seen_on, lead.last_seen_on ]

    Lead.sighted!(name: "Example Fusion", kind: "company", key: "search:1", label: "Search", times: 5, first: Date.new(2026, 10, 1), last: Date.new(2026, 10, 9))
    assert_equal [ 6, Date.new(2026, 10, 9), 2 ], [ lead.reload.seen_count, lead.last_seen_on, lead.sources.size ]
    assert_equal 2, Lead.sighted!(name: "Example Fusion", kind: "plant", key: "x", label: "x").then { Lead.count }
  end

  test "an ignored lead needs a reason; a decision keeps who and when" do
    lead = Lead.sighted!(name: "Not Nuclear Co", kind: "company", key: "k", label: "l")
    assert_raises(ActiveRecord::RecordInvalid) { lead.decide!("ignored", by: "human:tosin") }
    lead.decide!("ignored", by: "human:tosin", reason: "Not nuclear")
    assert_equal [ "ignored", "Not nuclear", "human:tosin" ], [ lead.status, lead.reason, lead.decided_by ]
  end
end
