require "test_helper"
load Rails.root.join("db/data/20261118170000_gain_nea_leads.rb")

# #257 and #805: GAIN's missing company sites and NEA's missing developers become company leads for the finder.
class GainNeaLeadsTest < ActiveSupport::TestCase
  def run_it = GainNeaLeads.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "every site and name is a waiting company lead with its list's label; a rerun adds nothing" do
    run_it
    aalo = Lead.find_by!(name: "https://aalo.com")
    assert_equal [ "company", "new", "gain-2026-08:aalo.com", GainNeaLeads::GAIN_LABEL, "https://aalo.com" ],
      [ aalo.kind, aalo.status, *aalo.sources.sole.values_at("key", "label", "url") ]
    terrestrial = Lead.find_by!(name: "Terrestrial Energy")
    assert_equal [ "nea-smr-3:terrestrial energy", nil ], terrestrial.sources.sole.values_at("key", "url")
    assert_includes LeadFinding.due, terrestrial
    assert_no_difference("Lead.count") { run_it }
    assert_equal GainNeaLeads::GAIN.size + GainNeaLeads::NEA.size, Lead.where("sources::text LIKE ?", "%not a source%").count
  end
end
