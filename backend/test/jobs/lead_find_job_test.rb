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
    skip "the finder is in" if defined?(DataQuality::Plugins::LeadFinder)
    LeadFindJob.finder = nil
    l = lead("Early Co")
    LeadFindJob.perform_now(l.id)
    assert_equal [ "new", 0, "Waiting for the finder" ], l.reload.values_at(:status, :find_attempts, :note)
  end

  test "at most PER_DAY finds a day; past that a lead waits for tonight, its tries untouched" do
    store, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    LeadFindJob.finder = ->(*) { Found.new(outcome: :proposed, reason: nil) }
    LeadFinding::PER_DAY.times { LeadFinding.take_today }
    l = lead("Over Co")
    LeadFindJob.perform_now(l.id)
    assert_equal [ "new", 0, LeadFinding::WAITING ], l.reload.values_at(:status, :find_attempts, :note)
    travel(1.day) { LeadFindJob.perform_now(l.id) }
    assert_equal "added", l.reload.status
  ensure
    Rails.cache = store
  end

  test "a person's decision during a find wins: the finder's result is dropped" do
    l = lead("Raced Co")
    LeadFindJob.finder = ->(found) { found.reload.decide!("ignored", by: "human:tosin", reason: "not ours"); Found.new(outcome: :proposed, reason: nil) }
    LeadFindJob.perform_now(l.id)
    assert_equal [ "ignored", "not ours" ], l.reload.values_at(:status, :reason)
  end

  test "a queued find for a lead no longer due does nothing (found already, or ignored)" do
    l = lead("Done Co", status: "added")
    calls = 0
    LeadFindJob.finder = ->(*) { calls += 1; Found.new(outcome: :proposed, reason: nil) }
    LeadFindJob.perform_now(l.id)
    l.update!(status: "ignored", reason: "no")
    LeadFindJob.perform_now(l.id)
    assert_equal 0, calls
  end

  test "a person taking over research clears the finder's retry, so it isn't picked up again" do
    l = lead("Retry Co", status: "researching", next_find_at: 1.hour.ago, find_attempts: 1, note: "Couldn't confirm: no site")
    l.decide!("researching", by: "human:tosin")
    assert_nil l.reload.next_find_at
    assert_not LeadFinding.due.exists?(id: l.id)
  end

  test "once the finder is in, the 2 am proposals leave company leads to it and keep plants" do
    assert_equal %w[company plant], LeadProposals.kinds(finder: false)
    assert_equal %w[plant], LeadProposals.kinds(finder: true)
  end

  test "not US or not nuclear closes the lead at once with the reason, no retry" do
    l = lead("Abroad Co")
    LeadFindJob.finder = ->(*) { Found.new(outcome: :not_us, reason: "Toronto head office") }
    LeadFindJob.perform_now(l.id)
    assert_equal [ "ignored", nil ], l.reload.values_at(:status, :next_find_at)
    assert_equal "Closed at check: not a US company: Toronto head office", l.reason
    assert_equal l.reason, LeadFinding.state(l)
  end

  test "a busy pipeline or a :retry outcome isn't a try: no attempt used, due again within the hour" do
    l = lead("Busy Co", find_attempts: 1)
    LeadFindJob.finder = ->(*) { raise DataQuality::Pipeline::AlreadyRunning, "match in progress" }
    LeadFindJob.perform_now(l.id)
    assert_equal [ "researching", 1, LeadFinding::BUSY ], l.reload.values_at(:status, :find_attempts, :note)
    assert_in_delta 1.hour.from_now, l.next_find_at, 1.minute
    travel(2.hours) do
      LeadFindJob.finder = ->(*) { Found.new(outcome: :retry, reason: "search limit reached") }
      LeadFindJob.perform_now(l.id)
      assert_equal 1, l.reload.find_attempts
    end
    travel(4.hours) do
      LeadFindJob.finder = ->(*) { Found.new(outcome: :busy, reason: "another run held the lock") }
      LeadFindJob.perform_now(l.id)
      assert_equal [ 1, LeadFinding::BUSY ], l.reload.values_at(:find_attempts, :note)
    end
  end

  test "nightly, Tosin's own leads go first" do
    lead("Older Co")
    travel(1.minute) { Lead.sighted!(name: "His Co", kind: "company", key: "admin:suggest:his co", label: CompanySuggestion::LABEL) }
    assert_equal "His Co", LeadFinding.due.first.name
  end

  test "an unconfirmed outcome that's really the finder's daily limit isn't a try" do
    l = lead("Limit Co")
    LeadFindJob.finder = ->(*) { Found.new(outcome: :unconfirmed, reason: "Today's limit of 50 finds is reached; tried again tomorrow") }
    LeadFindJob.perform_now(l.id)
    assert_equal [ "researching", 0, LeadFinding::BUSY ], l.reload.values_at(:status, :find_attempts, :note)
  end
end
