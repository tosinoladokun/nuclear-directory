require "test_helper"
load Rails.root.join("db/data/20261118160000_aalo_lead.rb")

# Infra, 18 Nov 2026: lead 105's name was the whole pasted line; it becomes Aalo Atomics with aalo.com, found again.
class AaloLeadTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  setup do
    Lead.find_by(id: 105)&.destroy!
    @lead = Lead.create!(id: 105, name: AaloLead::LINE, normalized_name: Lead.normalize(AaloLead::LINE), kind: "company", status: "researching",
      note: "Couldn't confirm: No site checked out", find_attempts: 1, next_find_at: 7.days.from_now,
      sources: [ { "key" => "#{CompanySuggestion::KEY}:x", "label" => CompanySuggestion::LABEL, "times" => 1, "first" => "2026-11-18", "last" => "2026-11-18" } ],
      seen_count: 1, first_seen_on: Date.new(2026, 11, 18), last_seen_on: Date.new(2026, 11, 18))
  end

  def run_it = AaloLead.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "renamed with its site, found again once the new release runs, tries reset; a rerun says so" do
    freeze_time do
      wait = DeployData::Migration::AFTER_DEPLOY_WAIT
      assert_enqueued_with(job: LeadFindJob, args: [ 105 ], at: wait.from_now) { run_it }
      @lead.reload
      assert_equal [ "Aalo Atomics", "researching", 0, wait.from_now, "https://www.aalo.com/" ],
        [ @lead.name, @lead.status, @lead.find_attempts, @lead.next_find_at, @lead.sources.sole["url"] ]
      assert_not_includes LeadFinding.due, @lead, "not before the new release runs (#1018)"
      assert_includes LeadFinding.due(now: wait.from_now), @lead
    end
    assert_match "already", run_it.output.sole
    assert_equal "human:tosin", AaloLead.new(reason: "x").by, "the deploy runner reads it before up"
  end
end
