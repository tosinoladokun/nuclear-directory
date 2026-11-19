require "test_helper"
load Rails.root.join("db/data/20261118170000_gain_nea_leads.rb")

# #257 and #805: GAIN's missing company sites and NEA's missing developers become company leads for the finder.
class GainNeaLeadsTest < ActiveSupport::TestCase
  def run_it = GainNeaLeads.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "every site and name is a waiting company lead with its list's label; a rerun adds nothing" do
    run_it
    flibe = Lead.find_by!(name: "https://flibe.com")
    assert_equal [ "company", "new", "gain-2026-08:flibe.com", GainNeaLeads::GAIN_LABEL, "https://flibe.com" ],
      [ flibe.kind, flibe.status, *flibe.sources.sole.values_at("key", "label", "url") ]
    otrera = Lead.find_by!(name: "Otrera New Energy")
    assert_equal [ "nea-smr-3:otrera new energy", nil ], otrera.sources.sole.values_at("key", "url")
    assert_includes LeadFinding.due, otrera
    assert_no_difference("Lead.count") { run_it }
    assert_equal GainNeaLeads::GAIN.size + GainNeaLeads::NEA.size - GainNeaLeads::NEA_IN_GAIN.size,
      Lead.where("sources::text LIKE ?", "%not a source%").count
  end

  test "no duplicates: a site a company or another lead has, and NEA names GAIN's sites already cover, are skipped" do
    Organization.create!(name: "HolosGen", website: "https://www.holosgen.com", verification_status: "pending")
    Lead.sighted!(name: "Aalo Atomics", kind: "company", key: "admin:suggest:aalo atomics", label: "Added in the admin", url: "https://www.aalo.com/")
    output = run_it.output.sole
    assert_not Lead.exists?(name: "https://holosgen.com")
    assert_not Lead.exists?(name: "https://aalo.com")
    assert_not Lead.exists?(name: "Deep Fission"), "GAIN's deepfission.com covers it"
    assert Lead.exists?(name: "Flibe Energy")
    assert_match "holosgen.com", output
  end
end
