require "test_helper"

# One lead pipeline (#752): every lead, whatever its source, is found the same
# way; one that can't be confirmed is tried weekly for a month, then closed.
class LeadFindJobTest < ActiveJob::TestCase
  Found = Data.define(:outcome, :reason)

  setup { @finder = LeadFindJob.finder }
  teardown { LeadFindJob.finder = @finder }

  def lead(name, status: "new", **attributes)
    Lead.sighted!(name:, kind: "company", key: "news:#{name}", label: "A press release").tap { |l| l.update!(status:, **attributes) }
  end

  test "nightly: waiting leads and due retries from any source; not triage, not a person's research, not a retry not yet due" do
    waiting = lead("Waiting Co")
    due = lead("Due Co", status: "researching", next_find_at: 1.hour.ago, find_attempts: 1)
    lead("Triage Co", status: "triage")
    lead("Someone Researching Co", status: "researching")
    lead("Later Co", status: "researching", next_find_at: 3.days.from_now, find_attempts: 1)
    seen = []
    LeadFindJob.finder = ->(l) { seen << l.name; Found.new(outcome: :proposed, reason: nil) }
    LeadFindJob.perform_now
    assert_equal [ "Waiting Co", "Due Co" ].sort, seen.sort
    assert_equal %w[added added], [ waiting, due ].map { |l| l.reload.status }
  end

  test "unconfirmed four times over a month closes it as couldn't confirm" do
    l = lead("Maybe Co")
    LeadFindJob.finder = ->(*) { Found.new(outcome: :unconfirmed, reason: "no website found") }
    3.times do |n|
      travel(n * 8.days) { LeadFindJob.perform_now(l.id) }
      assert_equal [ "researching", n + 1 ], l.reload.values_at(:status, :find_attempts)
    end
    travel(30.days) { LeadFindJob.perform_now(l.id) }
    l.reload
    assert_equal [ "ignored", 4, nil ], l.values_at(:status, :find_attempts, :next_find_at)
    assert_match "Couldn't confirm: no website found (tried 4 times over a month)", l.reason
  end

  test "without the finder, a lead waits untouched: no try used" do
    skip "the finder is in" if defined?(DataQuality::LeadFinder)
    LeadFindJob.finder = nil
    l = lead("Early Co")
    LeadFindJob.perform_now(l.id)
    assert_equal [ "new", 0, "Waiting for the finder" ], l.reload.values_at(:status, :find_attempts, :note)
  end
end
