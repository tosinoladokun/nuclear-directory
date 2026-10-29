require "test_helper"

# #572: a lead an official source names becomes a proposal by itself.
class LeadProposalsTest < ActiveSupport::TestCase
  setup do
    # Extracted already (past the recipients cap), so a lead from it may be proposed.
    @award = Source.create!(url: "https://api.usaspending.gov/award/1", source_kind: "usaspending_doe_awards", crawl_status: "ok", extracted_sha256: "x",
      content_text: "award_id,recipient_name,title\nA1,NEUTRON FORGE LLC,Advanced reactor fuel cladding\n")
  end

  test "a lead an official source names becomes a claim quoting that line; the lead is marked researching" do
    lead = Lead.sighted!(name: "NEUTRON FORGE LLC", kind: "company", key: "awards:#{@award.id}", label: "DOE awards", url: @award.url)
    assert_equal 1, LeadProposals.run
    claim = Candidate.find_by!(kind: "organization", source: @award)
    assert_equal [ "new", "Neutron Forge", [ "NEUTRON FORGE LLC" ] ], [ claim.status, claim.payload["name"], claim.payload["aliases"] ],
      "named as people read it, the registry spelling kept as another name"
    assert_equal "A1,NEUTRON FORGE LLC,Advanced reactor fuel cladding", claim.quote
    assert lead.reload.status_researching?
    assert_equal 0, LeadProposals.run, "once"
  end

  test "a lead from an unofficial source, or one the text doesn't name, stays in the table" do
    press = Source.create!(url: "https://press.example.com/a", source_kind: "trade_press", crawl_status: "ok", content_text: "Weak Fission raises money.")
    weak = Lead.sighted!(name: "Weak Fission", kind: "company", key: "news:x", label: "News", url: press.url)
    unnamed = Lead.sighted!(name: "Other Name Co", kind: "company", key: "awards:#{@award.id}", label: "DOE awards", url: @award.url)
    assert_equal 0, LeadProposals.run
    assert weak.reload.status_new?
    assert unnamed.reload.status_new?
  end

  test "a proposal survives its source being extracted again" do
    Lead.sighted!(name: "NEUTRON FORGE LLC", kind: "company", key: "awards:#{@award.id}", label: "DOE awards", url: @award.url)
    LeadProposals.run
    stale = DataQuality::Stages::Extract.allocate.send(:stale, @award)
    assert_empty stale.where(kind: "organization")
  end

  test "a name the directory already has is never proposed" do
    known = Organization.create!(name: "Neutron Forge", verification_status: "verified", verified_by: "human:tosin")
    known.aliases.create!(alias: "Neutron Forge")
    lead = Lead.sighted!(name: "NEUTRON FORGE LLC", kind: "company", key: "awards:#{@award.id}", label: "DOE awards", url: @award.url)
    assert_equal 0, LeadProposals.run
    assert lead.reload.status_new?
  end

  test "whole names only, and an award waiting for its night isn't proposed (the recipients cap)" do
    ge = Lead.sighted!(name: "GE", kind: "company", key: "awards:#{@award.id}", label: "DOE awards", url: @award.url)
    waiting = Source.create!(url: "https://api.usaspending.gov/award/2", source_kind: "usaspending_doe_awards", crawl_status: "ok",
      content_text: "award_id,recipient_name\nA2,WAITING FISSION LLC\n")
    later = Lead.sighted!(name: "WAITING FISSION LLC", kind: "company", key: "awards:#{waiting.id}", label: "DOE awards", url: waiting.url)
    assert_equal 0, LeadProposals.run
    assert ge.reload.status_new?, "GE isn't named by NEUTRON FORGE"
    assert later.reload.status_new?
  end
end
