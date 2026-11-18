require "test_helper"
load Rails.root.join("db/data/20261118160000_aalo_lead.rb")

# Infra, 18 Nov 2026: lead 105's name was the whole pasted line; it becomes Aalo Atomics with aalo.com, found again.
class AaloLeadTest < ActiveSupport::TestCase
  setup do
    Lead.find_by(id: 105)&.destroy!
    @lead = Lead.create!(id: 105, name: AaloLead::LINE, normalized_name: Lead.normalize(AaloLead::LINE), kind: "company", status: "researching",
      note: "Couldn't confirm: No site checked out", find_attempts: 1, next_find_at: 7.days.from_now,
      sources: [ { "key" => "#{CompanySuggestion::KEY}:x", "label" => CompanySuggestion::LABEL, "times" => 1, "first" => "2026-11-18", "last" => "2026-11-18" } ],
      seen_count: 1, first_seen_on: Date.new(2026, 11, 18), last_seen_on: Date.new(2026, 11, 18))
  end

  def run_it = AaloLead.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "renamed with its site, due tonight with its tries reset; a rerun says so" do
    run_it
    @lead.reload
    assert_equal [ "Aalo Atomics", "new", 0, nil, "https://www.aalo.com/" ], [ @lead.name, @lead.status, @lead.find_attempts, @lead.next_find_at, @lead.sources.sole["url"] ]
    assert_includes LeadFinding.due, @lead
    assert_match "already", run_it.output.sole
  end
end
