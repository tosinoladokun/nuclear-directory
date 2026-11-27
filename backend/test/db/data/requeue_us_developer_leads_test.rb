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
    nucube = stuck(125, "nucube.energy", url: "https://www.nucube.energy")
    fanco = stuck(114, "fanuclear.com", url: "https://fanuclear.com", tries: 1)
    named = stuck(92, "Valar Atomics")

    output = nil
    assert_enqueued_jobs 4, only: LeadFindJob do
      output = run_it.output.join("\n")
    end

    # Waits as researching until the new release finds it (#1018).
    assert_equal [ "NuCube Energy", "researching", 0 ], nucube.reload.attributes.values_at("name", "status", "find_attempts")
    assert nucube.next_find_at.future?
    assert_includes Directory::Leads.find(125).urls, RequeueUsDeveloperLeads::OWN_PAGES[125]
    assert_equal [ "First American Nuclear", "first american nuclear", 0 ], fanco.reload.attributes.values_at("name", "normalized_name", "find_attempts")
    assert_equal fanco, Lead.sighted!(name: "First American Nuclear", kind: "company", key: "nea:later", label: "NEA list"), "no duplicate later (Copilot)"
    assert_equal [ "Valar Atomics", 0, "human:tosin" ], named.reload.attributes.values_at("name", "find_attempts", "decided_by")
    scaled = Lead.find_by!(normalized_name: "scaled atomics")
    assert_equal [ "Scaled Atomics", "researching" ], [ scaled.name, scaled.status ]
    assert_includes output, "Lead 125 queued again as \"NuCube Energy\" with its own page (had used 2 of its tries)"
    assert_includes output, "Lead 110 is gone; nothing to do"
    assert_not_includes output, "Lead 116", "116 is Hadron again: only 110 is queued (DQ)"
  end

  test "Hadron's name-only lead gets its own story page; its duplicate 116 is never queued (DQ)" do
    hadron = stuck(110, "Hadron Energy")
    duplicate = stuck(116, "hadronenergy.com", url: "https://hadronenergy.com")
    run_it
    assert_equal "Hadron Energy", hadron.reload.name
    assert_includes Directory::Leads.find(110).urls, RequeueUsDeveloperLeads::OWN_PAGES[110]
    assert_equal [ 2, "researching" ], duplicate.reload.attributes.values_at("find_attempts", "status")
  end

  test "a website-only lead isn't renamed onto another lead that already has the name (Copilot)" do
    stuck(124, "deepfission.com", url: "https://deepfission.com")
    other = Lead.sighted!(name: "Deep Fission", kind: "company", key: "nea:other", label: "NEA list")
    assert_includes run_it.output.join("\n"), "Lead 124 (deepfission.com) left as it is: lead #{other.id} is already Deep Fission"
    assert_equal "deepfission.com", Lead.find(124).name
  end

  test "a lead a person decided is left; a rerun changes nothing" do
    decided = stuck(127, "Nuclearis Energy", url: "https://nuclearisenergy.com", status: "ignored")
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
