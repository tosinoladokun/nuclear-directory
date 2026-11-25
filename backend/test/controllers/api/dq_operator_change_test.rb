require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #930: Data Quality proposes a plant's new operator. Two claims, each Tosin's
# to decide on its own: the old operates link ends, the new one is added.
class Api::DqOperatorChangeTest < ActionDispatch::IntegrationTest
  TOKEN = "dq-test-token".freeze
  QUOTE = "Vistra Corp. completed its acquisition of Energy Harbor and now operates the Davis-Besse plant.".freeze

  setup do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    human = { verification_status: "verified", verified_by: "human:tosin" }
    @plant = Facility.create!(name: "Davis-Besse", facility_type: "power_reactor", state: "OH", **human)
    @harbor = Organization.create!(name: "Energy Harbor", **human)
    @vistra = Organization.create!(name: "Vistra", **human)
    [ @harbor, @vistra ].each { |company| company.aliases.create!(alias: company.name) }
    @vistra.aliases.create!(alias: "Vistra Energy Corp")
    @page = Source.create!(url: "https://example.com/vistra-energy-harbor", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: QUOTE)
    @old = FacilityRelationship.create!(organization: @harbor, facility: @plant, relationship_type: "operates", **human)
    Evidence.create!(subject: @old, source: @page, quote: "Energy Harbor operates Davis-Besse.", found_by: "human")
  end

  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  def act(*rows) = post(api_dq_matching_path, params: { actions: rows }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" })
  def results = response.parsed_body["results"]
  def change(target: @plant.id, from: @harbor.id, to: @vistra.id, since: "2024-03-01", quote: QUOTE, **rest) =
    { action: "propose_operator_change", target:, from:, to:, since:, quote:, source_url: @page.url, reason: "Vistra's release", **rest }
  def match! = DataQuality::Stages::Match.call(plugin: DummyPlugin.new)

  test "two claims, each a decision for Tosin on its own: the old link ends (a change), the new one is added; approving both replaces the operator" do
    act(change)
    assert results.sole["ok"], results.inspect
    added, ended = results.sole["created_ids"].map { |id| Candidate.find(id) }
    assert_equal({ "organization" => { "name" => "Vistra" }, "facility" => { "name" => "Davis-Besse" }, "relationship_type" => "operates",
                   "started_on" => "2024-03-01" }, added.payload)
    assert_equal "2024-03-01", ended.payload["ended_on"]
    assert_equal "Energy Harbor stopped operating the plant Davis-Besse on 1 Mar 2024.", DataQuality::Claim.describe(ended)
    assert_match "Vistra operates Davis-Besse from 2024-03-01, replacing Energy Harbor", added.notes

    match!
    assert_equal [ "FacilityRelationship", @old.id ], ended.reload.values_at(:subject_type, :subject_id), ended.notes
    assert_equal "change", DataQuality::Review.inbox_kind(ended)
    assert added.reload.subject_id, added.notes
    assert_equal "new_fact", DataQuality::Review.inbox_kind(added)
    assert_nil @old.reload.ended_on, "nothing changes before Tosin decides"

    [ added, ended ].each do |claim|
      assert_equal DataQuality::Review::OPERATOR_CHANGE, DataQuality::Review.held_reason(claim)
      act({ id: claim.id, action: "recommend", verdict: "approve", reason: "Vistra's release" })
    end
    assert_empty OwnerInbox.new.checked.map { |entry| entry.item.candidate_id } & [ added.id, ended.id ], "never in Yes to all, even with Data Quality's approve"
    forced = [ added, ended ].map do |claim|
      claim.reload
      DataQuality::Recommendations::Item.new(candidate_id: claim.id, call: claim.dq_recommendation, reason: claim.dq_reason, snapshot: claim.dq_payload_sha256,
        claim: nil, subject_type: claim.subject_type, subject_id: claim.subject_id, why: nil, waiting: true)
    end
    assert DataQuality::Recommendations.accept(forced, by: "human:tosin", first_hand: true).none?(&:ok?), "a bulk accept refuses them under the lock too"
    assert_nil @old.reload.ended_on

    [ ended, added ].each { |claim| assert DataQuality::Review.approve([ claim.id ], by: "human:tosin").sole.ok?, claim.reload.notes }
    assert_equal Date.new(2024, 3, 1), @old.reload.ended_on
    new_link = FacilityRelationship.find_by!(organization: @vistra, facility: @plant, relationship_type: "operates")
    assert_equal [ "verified", Date.new(2024, 3, 1) ], [ new_link.verification_status, new_link.started_on ]
  end

  test "refused: a quote that doesn't name the new operator, no current link, a link already there, a bad or future date, one company" do
    other = Facility.create!(name: "Perry", facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    act(change(quote: "Energy Harbor was acquired in 2024."),
      change(target: other.id),
      change(since: "2030-01-01"),
      change(since: "March 2024"),
      change(to: @harbor.id),
      change(from: "", to: ""),
      change(quote: "Vistranova operates it."))
    assert_match "must name the new operator (Vistra or Vistra Energy Corp)", results[0]["error"]
    assert_match "Energy Harbor has no current operates link to Perry", results[1]["error"]
    assert_match "can't be in the future", results[2]["error"]
    assert_match "like 2024-03-01", results[3]["error"]
    assert_match "the same company", results[4]["error"]
    assert_match "give from", results[5]["error"]
    assert_match "must name the new operator", results[6]["error"], "a whole word, not part of another"

    FacilityRelationship.create!(organization: @vistra, facility: @plant, relationship_type: "operates", verification_status: "pending")
    act(change)
    assert_match "Vistra already has an operates link to Davis-Besse", results.sole["error"]

    @old.update_columns(ended_on: Date.new(2024, 3, 1))
    third = Organization.create!(name: "Third Co", verification_status: "verified", verified_by: "human:tosin")
    act(change(to: third.id, quote: "Third Co operates it."))
    assert_match "has no current operates link", results.sole["error"], "an ended link isn't current"
  end

  test "an alias in the quote names the operator; each claim can be undone; a retry with its request_key returns both" do
    act(change(request_key: "op-1", quote: "Vistra Energy Corp now runs Davis-Besse."))
    ids = results.sole["created_ids"]
    assert_equal 2, ids.size, results.inspect
    act(change(request_key: "op-1", quote: "Vistra Energy Corp now runs Davis-Besse."))
    assert_equal ids, results.sole["created_ids"]
    DqAction.where(candidate_id: ids).find_each { |action| assert_nil DataQuality::Matching.undo(action.id) }
    assert_equal %w[rejected rejected], Candidate.where(id: ids).order(:id).pluck(:status)
  end

  test "another plant of the same name goes to review, never that plant" do
    act(change)
    claims = results.sole["created_ids"].map { |id| Candidate.find(id) }
    # Renamed before matching, and another plant now has the name the claims carry.
    @plant.update!(name: "Davis-Besse Nuclear Power Station")
    older = Facility.create!(name: "Davis-Besse", facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    match!
    claims.each do |claim|
      assert_nil claim.reload.subject_id
      assert_match "proposed for plant ##{@plant.id}, but facility matches plant ##{older.id}", claim.notes
    end
  end
end
