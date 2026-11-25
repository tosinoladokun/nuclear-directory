require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #930: Data Quality proposes a plant's new operator. Two claims, each Tosin's
# to decide on its own: the old operates link ends, the new one is added.
class Api::DqOperatorChangeTest < ActionDispatch::IntegrationTest
  TOKEN = "dq-test-token".freeze
  QUOTE = "On March 1, 2024 Vistra Corp. completed its acquisition of Energy Harbor and now operates the Davis-Besse plant.".freeze
  # Data Quality's real pair (PM, 25 Nov: option a): the plant and new operator from one page, the date from another.
  NAMED = "Vistra (NYSE: VST) and Energy Harbor today received approval from the Nuclear Regulatory Commission (NRC) to transfer the " \
    "operating licenses of Energy Harbor's three nuclear plants - Beaver Valley, Davis-Besse, and Perry - to Vistra.".freeze
  DATED = "On March 1, 2024 Vistra closed on the acquisition of Energy Harbor, which added more than 4,000 MW of nuclear generation to its portfolio".freeze

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

  test "with a second quote for the date (PM, 25 Nov): three claims, each quote checked against its own source and kept as evidence" do
    dated_page = Source.create!(url: "https://example.com/vistra-q1-2024", source_kind: "dummy", crawl_status: "ok", content_sha256: "q1", content_text: DATED)
    @page.update!(content_text: NAMED)
    act(change(quote: NAMED, since_quote: DATED, since_source_url: dated_page.url))
    assert results.sole["ok"], results.inspect
    named, ended, started = results.sole["created_ids"].map { |id| Candidate.find(id) }
    assert_equal [ [ @page.id, NAMED, nil ], [ dated_page.id, DATED, "2024-03-01" ], [ dated_page.id, DATED, "2024-03-01" ] ],
      [ named, ended, started ].map { |claim| [ claim.source_id, claim.quote, claim.payload["started_on"] || claim.payload["ended_on"] ] }
    assert_equal [ "Vistra", "Energy Harbor", "Vistra" ], [ named, ended, started ].map { |claim| claim.payload.dig("organization", "name") }
    assert_match "Named by: \"Vistra (NYSE: VST)", ended.notes

    match!
    [ named, ended, started ].each { |claim| assert claim.reload.subject_id, claim.notes }
    assert_equal named.subject_id, started.subject_id, "the date claim is on the new link"
    assert_equal @old.id, ended.subject_id
    [ named, ended, started ].each { |claim| assert_equal DataQuality::Review::OPERATOR_CHANGE, DataQuality::Review.held_reason(claim) }

    [ named, started, ended ].each { |claim| assert DataQuality::Review.approve([ claim.id ], by: "human:tosin").sole.ok?, claim.reload.notes }
    link = FacilityRelationship.find(named.subject_id)
    assert_equal [ "verified", Date.new(2024, 3, 1) ], [ link.verification_status, link.started_on ]
    assert_equal [ @page.id, dated_page.id ].sort, link.evidence.pluck(:source_id).sort, "both quotes are its evidence"
    assert_equal Date.new(2024, 3, 1), @old.reload.ended_on
    assert_includes @old.evidence.pluck(:quote), DATED
  end

  test "the date must be stated: by the quote, or by since_quote" do
    act(change(quote: NAMED),
      change(quote: NAMED, since_quote: "Vistra closed on the acquisition of Energy Harbor in 2024."),
      change(quote: NAMED, since_quote: "On March 10, 2024 Vistra closed on the acquisition."),
      change(quote: NAMED, since_quote: "In March 2024 Vistra closed on the acquisition of Energy Harbor."),
      change(quote: NAMED, since: "2024-03-02", since_quote: "In March 2024 Vistra closed on the acquisition of Energy Harbor."))
    assert_match "the quote must state the date 1 March 2024, or give it in since_quote", results[0]["error"]
    assert_match "the since quote must state the date 1 March 2024", results[1]["error"]
    assert_match "the since quote must state the date", results[2]["error"], "March 10 isn't March 1"
    assert results[3]["ok"], "a month on its own states the 1st, as DATA.md stores it: #{results[3].inspect}"
    assert_match "the since quote must state the date 2 March 2024", results[4]["error"]
    %w[2024-03-01 March\ 1,\ 2024 Mar.\ 1,\ 2024 1st\ March\ 2024 1\ March\ 2024].each do |form|
      assert DataQuality::Matching.date_stated?("closed on #{form}.", Date.new(2024, 3, 1)), form
    end
    assert_not DataQuality::Matching.date_stated?("closed on 11 March 2024.", Date.new(2024, 3, 1))
  end

  test "refused: a quote that doesn't name the new operator, no current link, a link already there, a bad or future date, one company" do
    other = Facility.create!(name: "Perry", facility_type: "power_reactor", verification_status: "verified", verified_by: "human:tosin")
    act(change(quote: "On March 1, 2024 Energy Harbor was acquired."),
      change(target: other.id),
      change(since: "2030-01-01"),
      change(since: "March 2024"),
      change(to: @harbor.id),
      change(from: "", to: ""),
      change(quote: "Vistranova operates it from March 1, 2024."))
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
    act(change(to: third.id, quote: "Third Co operates it from 1 March 2024."))
    assert_match "has no current operates link", results.sole["error"], "an ended link isn't current"
  end

  test "an alias in the quote names the operator; each claim can be undone; a retry with its request_key returns both" do
    act(change(request_key: "op-1", quote: "Vistra Energy Corp runs Davis-Besse since 2024-03-01."))
    ids = results.sole["created_ids"]
    assert_equal 2, ids.size, results.inspect
    act(change(request_key: "op-1", quote: "Vistra Energy Corp runs Davis-Besse since 2024-03-01."))
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
