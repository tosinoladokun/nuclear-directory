require "test_helper"
load Rails.root.join("db/data/20261127230000_requeue_us_developer_leads_again.rb")

# #1015: the US developers the finder still missed after #987, and NuCube, are found again (never Nuclearis, which
# Tosin said no to); decided leads and a rerun are left alone.
class RequeueUsDeveloperLeadsAgainTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def stuck(id, name, status: "researching", tries: 1)
    Lead.where(id:).delete_all
    lead = Lead.sighted!(name:, kind: "company", key: "nea:805:#{id}", label: "NEA list")
    lead.update_columns(id:, status:, find_attempts: tries, next_find_at: 7.days.from_now, reason: (status == "ignored" ? "not US" : nil))
    Lead.find(id)
  end

  def run_it = RequeueUsDeveloperLeadsAgain.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "queues the five again with tries reset; a decided lead and a rerun are left" do
    terrestrial = stuck(127, "Terrestrial Energy")
    stuck(112, "Deep Fission")
    added = stuck(125, "NuCube Energy", status: "added", tries: 1)
    nuclearis = stuck(124, "Nuclearis Energy")

    output = nil
    assert_enqueued_jobs 2, only: LeadFindJob do
      output = run_it.output.join("\n")
    end
    assert_equal [ "Terrestrial Energy", "new", 0, nil ], terrestrial.reload.attributes.values_at("name", "status", "find_attempts", "next_find_at")
    assert_includes output, "Lead 127 (Terrestrial Energy) queued again (had used 1 of its tries)"
    assert_includes output, "Lead 125 (NuCube Energy) is added now (a person decided it); left as it is"
    assert_equal [ 1, "researching" ], nuclearis.reload.attributes.values_at("find_attempts", "status"), "Tosin said no to Nuclearis"
    assert_not_includes output, "Lead 124"
    assert_includes output, "Lead 110 is gone; nothing to do"
    assert_equal "added", added.reload.status

    assert_no_enqueued_jobs only: LeadFindJob do
      assert_includes run_it.output.join("\n"), "Lead 127 (Terrestrial Energy) was already queued again for #1015; left as it is"
    end
  end
end
