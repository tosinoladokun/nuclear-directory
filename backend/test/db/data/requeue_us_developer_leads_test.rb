require "test_helper"
load Rails.root.join("db/data/20261127200000_requeue_us_developer_leads.rb")

# #987: the stuck US developer leads are found again with the fixed finder: tries back to 0, website-only ones named,
# NuCube's own release added, Scaled Atomics added; decided leads and a rerun are left alone.
class RequeueUsDeveloperLeadsTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def stuck(id, name, url: nil, status: "researching", tries: 2)
    Lead.where(id:).delete_all
    lead = Lead.sighted!(name:, kind: "company", key: "nea:805:#{id}", label: "NEA list", url:)
    lead.update_columns(id:, status:, find_attempts: tries, next_find_at: 3.days.from_now, reason: (status == "ignored" ? "not US" : nil))
    Lead.find(id)
  end

  def run_it = RequeueUsDeveloperLeads.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "resets the stuck leads, names the website-only ones, adds NuCube's release and Scaled Atomics" do
    nucube = stuck(112, "nucube.energy", url: "https://www.nucube.energy")
    fanco = stuck(114, "fanuclear.com", url: "https://fanuclear.com", tries: 1)
    named = stuck(92, "Valar Atomics")

    output = nil
    assert_enqueued_jobs 4, only: LeadFindJob do
      output = run_it.output.join("\n")
    end

    assert_equal [ "NuCube Energy", "new", 0, nil ], nucube.reload.attributes.values_at("name", "status", "find_attempts", "next_find_at")
    assert_includes Directory::Leads.find(112).urls, RequeueUsDeveloperLeads::OWN_PAGES["nucube.energy"]
    assert_equal [ "First American Nuclear", 0 ], fanco.reload.attributes.values_at("name", "find_attempts")
    assert_equal [ "Valar Atomics", 0, "human:tosin" ], named.reload.attributes.values_at("name", "find_attempts", "decided_by")
    scaled = Lead.find_by!(normalized_name: "scaled atomics")
    assert_equal [ "Scaled Atomics", "new" ], [ scaled.name, scaled.status ]
    assert_includes output, "Lead 112 queued again as \"NuCube Energy\" with its own page (had used 2 of its tries)"
    assert_includes output, "Lead 110 is gone; nothing to do"
    assert_not_includes output, "Lead 116", "116 is Hadron again: only 110 is queued (DQ)"
  end

  test "Hadron's lead gets its own story page; its duplicate 116 is never queued (DQ)" do
    hadron = stuck(110, "hadronenergy.com", url: "https://hadronenergy.com")
    duplicate = stuck(116, "Hadron Energy")
    run_it
    assert_equal "Hadron Energy", hadron.reload.name
    assert_includes Directory::Leads.find(110).urls, RequeueUsDeveloperLeads::OWN_PAGES["hadronenergy.com"]
    assert_equal [ 2, "researching" ], duplicate.reload.attributes.values_at("find_attempts", "status")
  end

  test "a lead a person decided is left; a rerun changes nothing" do
    decided = stuck(125, "Nuclearis Energy", url: "https://nuclearisenergy.com", status: "ignored")
    run_it
    assert_equal [ "ignored", 2 ], decided.reload.attributes.values_at("status", "find_attempts")

    stuck(124, "Deep Fission", url: "https://deepfission.com")
    run_it
    assert_no_enqueued_jobs only: LeadFindJob do
      output = run_it.output.join("\n")
      assert_includes output, "Lead 124 (Deep Fission) was already queued again for #987; left as it is"
      assert_includes output, "Scaled Atomics was already added for #987; left as it is"
    end
  end
end
