require "test_helper"
require_relative "support/dummy_plugin"

# The Review API the admin calls (#85), against the real directory.
class DataQuality::ReviewTest < ActiveSupport::TestCase
  include ReviewHelpers
  Review = DataQuality::Review
  BY = "human:tosin"

  class Recommend
    def call(candidate) = DataQuality::Verdict.new(outcome: :publish, confidence: 0.9, reason: "The row names #{candidate.payload['name']}.")
  end

  setup do
    @source = Source.create!(url: "https://www.nrc.gov/test/review.html", source_kind: "dummy", crawl_status: "ok",
      title: "NRC test page")
  end

  def candidate(kind, payload, quote: "a quote") = Candidate.create!(source: @source, kind:, payload:, quote:)
  def run_stage(stage, **) = DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: stage, **).last

  # ---- candidates

  test "lists recommended candidates as the admin shows them, by run" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    verify = run_stage("verify", verifier: Recommend.new)

    item = Review.candidates(queue: :recommended).sole

    assert_equal [ c.id, "organization", "There is a company named “Imaginary Fission Co”.", "a quote" ],
      [ item.candidate_id, item.kind, item.claim, item.quote ]
    assert_equal [ @source.url, "NRC test page" ], [ item.source.url, item.source.title ]
    assert_equal [ "recommend_publish", 0.9, verify.id ], [ item.ai_recommendation, item.ai_confidence.to_f, item.verify_run_id ]
    assert_equal({}, item.differences)
    assert_equal [ c.id ], Review.candidates(run_id: verify.id).map(&:candidate_id)
    assert_empty Review.candidates(run_id: verify.id + 1)
  end

  test "the needs-review queue filters by reason, and shows both values for a conflict" do
    unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ")
    unit.verify!(by: BY)
    conflict = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    candidate("organization", { "name" => "Imaginary Fission Co" }, quote: "not in the source")
    @source.update!(content_text: "Some other text entirely.")
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)

    item = Review.candidates(queue: :needs_review, reason: "human-verified").sole

    assert_equal conflict.id, item.candidate_id
    assert_equal({ "state" => [ "NJ", "DE" ] }, item.differences)
    assert_equal 2, Review.candidates(queue: :needs_review).size
    assert_equal [ [ "The cited quote isn't in the source as stored, so it can't be checked", 1 ],
      [ "human-verified state is NJ; this source says DE", 1 ] ], Review.reasons
  end

  test "approves in bulk, recording who decided" do
    a = candidate("organization", { "name" => "Alpha Fission Co" })
    b = candidate("organization", { "name" => "Beta Fission Co" })
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)

    results = Review.approve([ a.id, b.id ], by: BY)

    assert results.all?(&:ok?)
    [ a, b ].each(&:reload)
    assert [ a, b ].all?(&:status_merged?)
    assert_equal [ BY, BY ], [ a.reviewed_by, b.reviewed_by ]
    assert a.reviewed_at
    assert_empty Review.candidates
  end

  test "edit, then approve: the edited value is published; link ends and slug can't be edited" do
    c = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)

    result = Review.edit_and_approve(c.id, attributes: { "state" => "NJ" }, by: BY, reason: "NRC lists the nearby city's state")

    assert result.ok?
    unit = Facility.find(result.ref.id)
    assert_equal [ "NJ", true ], [ unit.state, unit.human_verified? ]
    event = Review.history(type: "Facility", id: unit.id).first
    assert_equal "NRC lists the nearby city's state", event.reason

    link = candidate("facility_relationship", { "organization" => { "name" => "X" }, "facility" => { "name" => "Y" },
      "relationship_type" => "operates" })
    refused = Review.edit_and_approve(link.id, attributes: { "facility" => { "name" => "Z" } }, by: BY)
    assert_match "can't edit facility", refused.errors.join
    refused = Review.edit_and_approve(link.id, attributes: { "facility_id" => facilities(:vogtle).id }, by: BY)
    assert_match "can't edit facility_id", refused.errors.join, "nor by id"
  end

  test "a reason from reasons() lists its group, whatever names it blanked" do
    [ "Alpha Fission Co", "Beta Fission Co" ].each do |name|
      Candidate.create!(source: @source, kind: "organization", payload: { "name" => name }, quote: "q", status: "needs_review",
        notes: %(Looks like "#{name.split.first} Nuclear": the same leading word))
    end

    # A note about a link's end starts with that end; it's the same reason.
    Candidate.create!(source: @source, kind: "facility_relationship", payload: {}, quote: "q", status: "needs_review",
      notes: %(organization: Looks like "Gamma Nuclear": the same leading word))

    reason, count = Review.reasons.sole

    assert_equal [ 'Looks like "…"', 3 ], [ reason, count ]
    assert_equal 3, Review.candidates(queue: :needs_review, reason:).size
  end

  test "a candidate on a human-verified link shows the link's differing details, and verify sends it to review" do
    link = FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle),
      relationship_type: "owns", ownership_pct: 40, description: "Minority owner")
    link.verify!(by: BY)
    c = candidate("facility_relationship", { "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => facilities(:vogtle).name }, "relationship_type" => "owns", "ownership_pct" => 75,
      "description" => "Minority owner" })
    same = candidate("facility_relationship", { "organization" => { "name" => "TerraPower" },
      "facility" => { "name" => facilities(:vogtle).name }, "relationship_type" => "owns", "ownership_pct" => "40.0" })
    [ c, same ].each { |x| x.update!(status: "matched", subject_type: "FacilityRelationship", subject_id: link.id) }

    run_stage("verify", verifier: Recommend.new)

    assert c.reload.status_needs_review?
    assert_equal "human-verified ownership is 40; this source says 75", c.notes
    assert_equal({ "ownership_pct" => [ "40", "75" ] }, Review.candidates(queue: :needs_review).sole.differences)
    assert_equal "recommend_publish", same.reload.ai_recommendation, "40 and 40.0 are the same share"
  end

  test "a company role's role and a company technology's technology identify the fact, so they can't be edited" do
    role = candidate("organization_role", { "organization" => { "name" => "TerraPower" }, "role" => "reactor_vendor" })
    tech = candidate("organization_technology", { "organization" => { "name" => "TerraPower" }, "technology" => "fusion" })

    assert_match "can't edit role", Review.edit_and_approve(role.id, attributes: { "role" => "utility" }, by: BY).errors.join
    assert_match "can't edit technology", Review.edit_and_approve(tech.id, attributes: { "technology" => "smr" }, by: BY).errors.join

    link = OrganizationRole.create!(organization: organizations(:terrapower), role: Role.create!(key: "reactor_vendor", name: "Reactor vendor"))
    assert_match "can't edit role", Review.approve_fact(type: "OrganizationRole", id: link.id, by: BY,
      attributes: { role: "utility" }).errors.join
  end

  test "an unchanged role or technology, sent back by the edit form, is approved" do
    vendor = Role.create!(key: "reactor_vendor", name: "Reactor vendor")
    fusion = Technology.create!(key: "fusion", name: "Fusion")
    role = candidate("organization_role", { "organization" => { "name" => "TerraPower" }, "role" => "reactor_vendor" })
    tech = candidate("organization_technology", { "organization" => { "name" => "TerraPower" }, "technology" => "fusion" })
    # As match leaves them: attached to the pending fact each proposes.
    role.update!(status: "matched", subject: OrganizationRole.create!(organization: organizations(:terrapower), role: vendor))
    tech.update!(status: "matched", subject: OrganizationTechnology.create!(organization: organizations(:terrapower), technology: fusion))

    [ [ role, { "role" => "reactor_vendor" } ], [ tech, { "technology" => "fusion" } ] ].each do |claim, unchanged|
      result = Review.edit_and_approve(claim.id, attributes: unchanged, by: BY)
      assert result.ok?, result.errors.to_sentence
      assert claim.reload.status_merged?
    end
  end

  test "id can't be edited, and an id in a payload never picks the record written" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    assert_match "can't edit id", Review.edit_and_approve(c.id, attributes: { "id" => organizations(:terrapower).id }, by: BY).errors.join

    sneaky = candidate("organization", { "name" => "Sneaky Co", "id" => organizations(:terrapower).id })
    assert Review.approve([ sneaky.id ], by: BY).sole.ok?
    assert_equal "TerraPower", organizations(:terrapower).reload.name, "not overwritten"
    assert_not_equal organizations(:terrapower).id, sneaky.reload.subject_id
  end

  test "a link's type and a plant's parent site can't be edited; payload ends and slug are never written" do
    link = candidate("facility_relationship", { "organization" => { "name" => "TerraPower" }, "facility" => { "name" => "Vogtle" },
      "relationship_type" => "owns" })
    unit = candidate("facility", { "name" => "Vogtle 3", "nrc_docket" => "05200025" })
    assert_match "can't edit relationship_type", Review.edit_and_approve(link.id, attributes: { "relationship_type" => "operates" }, by: BY).errors.join
    assert_match "can't edit parent_id", Review.edit_and_approve(unit.id, attributes: { "parent_id" => facilities(:vogtle).id }, by: BY).errors.join

    existing = FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle), relationship_type: "owns")
    sneaky = candidate("facility_relationship", { "organization" => { "name" => "TerraPower" }, "facility" => { "name" => "Vogtle" },
      "relationship_type" => "owns", "organization_id" => organizations(:westinghouse).id, "slug" => "hijacked" })
    sneaky.update!(status: "matched", subject_type: "FacilityRelationship", subject_id: existing.id)

    assert Review.approve([ sneaky.id ], by: BY).sole.ok?
    assert_equal organizations(:terrapower).id, existing.reload.organization_id, "an organization_id in the payload doesn't move the link"
  end

  test "the no-reason group lists the candidates with no notes" do
    blank = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Blank Co" }, quote: "q", status: "needs_review")
    Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Noted Co" }, quote: "q", status: "needs_review",
      notes: 'Looks like "X": same word')

    assert_includes Review.reasons.map(&:first), "no reason"
    assert_equal [ blank.id ], Review.candidates(queue: :needs_review, reason: "no reason").map(&:candidate_id)
  end

  test "an edited claim doesn't carry the verifier's confidence; an unchanged one does" do
    edited = candidate("facility", { "name" => "Hope Creek 1", "nrc_docket" => "05000354", "state" => "DE" })
    same = candidate("facility", { "name" => "Salem 1", "nrc_docket" => "05000272", "state" => "NJ" })
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)

    Review.edit_and_approve(edited.id, attributes: { "state" => "NJ" }, by: BY)
    Review.edit_and_approve(same.id, attributes: { "state" => "NJ" }, by: BY)

    confidence = ->(c) { Facility.find(c.reload.subject_id).evidence.where.not(crawl_run_id: nil).sole.confidence }
    assert_nil confidence.(edited), "the model checked DE, not NJ"
    assert_equal 0.9, confidence.(same).to_f
  end

  test "approving an alias adds it to its published company, as the human" do
    terrapower = organizations(:terrapower)
    terrapower.verify!(by: BY)
    c = candidate("organization_alias", { "organization" => { "name" => "TerraPower" }, "alias" => "TerraPower Isotopes" })
    run_stage("match")
    assert c.reload.status_needs_review?

    result = Review.approve([ c.id ], by: BY).sole

    assert result.ok?, result.errors.inspect
    assert_equal [ "Organization", terrapower.id ], [ result.ref.type, result.ref.id ]
    assert_includes terrapower.aliases.reload.pluck(:alias), "TerraPower Isotopes"
    assert c.reload.status_merged?
  end

  test "an alias waits for its company to be published, and needs a company that exists" do
    pending_co = Organization.find(Directory::FactWriter.write(:organization, { name: "Pending Fission Co" }).id)
    early = candidate("organization_alias", { "organization" => { "name" => "Pending Fission Co" }, "alias" => "PFC" })
    nowhere = candidate("organization_alias", { "organization" => { "name" => "Nobody Co" }, "alias" => "NC" })

    assert_match "Pending Fission Co isn't published; approve it first", Review.approve([ early.id ], by: BY).sole.errors.join
    assert_match "no company named \"Nobody Co\"", Review.approve([ nowhere.id ], by: BY).sole.errors.join
    assert_empty pending_co.aliases.where(alias: "PFC")
  end

  test "an item carries the record it's attached to" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)

    record = Review.candidates.sole.record

    assert_equal [ "Organization", c.reload.subject_id, "Imaginary Fission Co", "pending" ],
      [ record.type, record.id, record.name, record.verification_status ]
  end

  test "a failed edit-then-approve keeps the candidate's original values" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")

    result = Review.edit_and_approve(c.id, attributes: { "favourite_colour" => "blue" }, by: BY)

    assert_not result.ok?
    assert_match "unknown attributes", result.errors.join
    assert_equal({ "name" => "Imaginary Fission Co" }, c.reload.payload)
  end

  test "rejecting retires the record match proposed for it, as the human's decision" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    proposed = Organization.find(c.reload.subject_id)

    result = Review.reject([ c.id ], by: BY, reason: "Not a real company").sole

    assert result.ok?
    assert_equal [ "rejected", "Not a real company", BY ], [ c.reload.status, c.notes, c.reviewed_by ]
    assert_equal [ "rejected", BY ], [ proposed.reload.verification_status, proposed.verified_by ]
    assert_match "already rejected", Review.reject([ c.id ], by: BY).sole.errors.join
  end

  test "reopening sends a rejected candidate back through match and verify, keeping who and why (#228)" do
    unit = Facility.create!(name: "Salem 1", nrc_docket: "05000272", state: "NJ", verification_status: "verified", verified_by: BY)
    c = Candidate.create!(source: @source, kind: "facility", quote: "row", status: "rejected", subject_type: "Facility", subject_id: unit.id,
      payload: { "identify" => { "name" => "Salem", "state" => "NJ", "unit" => "1" }, "capacity_mw" => "1169.0" },
      ai_recommendation: "recommend_publish", ai_confidence: 0.9, ai_reason: "old", reviewed_by: BY, reviewed_at: 1.hour.ago)

    c.update!(notes: "Wrong state")

    result = Review.reopen([ c.id ], by: "human:pat", reason: "rejected while the unit's state was wrong (#197)").sole

    assert result.ok?
    c.reload
    assert_equal [ "new", nil, nil, nil ], [ c.status, c.subject_id, c.ai_recommendation, c.reviewed_by ]
    assert_equal "Reopened: rejected while the unit's state was wrong (#197)", c.notes
    assert_equal [ [ "human:pat", "rejected while the unit's state was wrong (#197)", BY, "Wrong state" ] ],
      c.reopenings.map { |r| r.values_at("by", "reason", "rejected_by", "rejection") }
    assert_match "isn't rejected", Review.reopen([ c.id ], by: BY, reason: "again").sole.errors.join
    assert unit.reload.verified?, "the unit itself is untouched"
  end

  test "a candidate isn't reopened when its record was retired, even by another candidate's proposal" do
    company = Organization.create!(name: "Imaginary Fission Co")
    c = Candidate.create!(source: @source, kind: "organization", quote: "q", status: "rejected", proposed_subject: false,
      subject_type: "Organization", subject_id: company.id, payload: { "name" => "Imaginary Fission Co" })
    company.reject!(by: BY, reason: "Not a real company")

    assert_match "decide that record first", Review.reopen([ c.id ], by: BY, reason: "why").sole.errors.join
    assert c.reload.status_rejected?
  end

  test "who reopened a candidate, and why, survive match, verify and the next decision" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    # Matched to a company another candidate proposed, so rejecting it retires nothing.
    c.reload.update!(proposed_subject: false)
    Review.reject([ c.id ], by: BY, reason: "Wrong company")

    reopened = Review.reopen([ c.id ], by: "human:pat", reason: "it was the right one").sole
    assert reopened.ok?, reopened.errors.inspect
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)
    approved = Review.approve([ c.id ], by: BY).sole
    assert approved.ok?, [ approved.errors, c.reload.attributes.slice("status", "notes", "ai_recommendation") ].inspect

    c.reload
    assert_equal [ "merged", BY ], [ c.status, c.reviewed_by ]
    assert_equal [ [ "human:pat", "it was the right one", BY, "Wrong company" ] ],
      c.reopenings.map { |r| r.values_at("by", "reason", "rejected_by", "rejection") }
  end

  test "a candidate whose rejection retired its proposal isn't reopened, and a reason is required" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    Review.reject([ c.id ], by: BY, reason: "Not a real company")

    assert_match "decide that record first", Review.reopen([ c.id ], by: BY, reason: "changed my mind").sole.errors.join
    assert c.reload.status_rejected?
    assert_raises(ArgumentError) { Review.reopen([ c.id ], by: BY, reason: " ") }
    assert_raises(ArgumentError) { Review.reopen([ c.id ], by: "agent:x", reason: "why") }
  end

  test "only a human decides, and says who" do
    assert_raises(ArgumentError) { Review.approve([], by: "agent:verifier/x") }
    assert_raises(ArgumentError) { Review.reject([], by: "") }
    assert_raises(ArgumentError) { Review.unpublish(type: "Organization", id: 1, by: "agent:x") }
    assert_raises(ArgumentError) { Review.approve([], by: "human:") }
    assert_raises(ArgumentError) { Review.approve([], by: "human:  ") }
  end

  test "a recommendation whose source changed isn't approved until verify checks it again" do
    @source.update!(content_text: "Imaginary Fission Co", content_sha256: "old")
    c = candidate("organization", { "name" => "Imaginary Fission Co" }, quote: "Imaginary Fission Co")
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)
    @source.update!(content_sha256: "new")

    result = Review.approve([ c.id ], by: BY).sole

    assert_match "its source changed after the verifier checked it", result.errors.join
    assert c.reload.status_matched?
  end

  test "an unknown claim id comes back as an error, not an exception" do
    result = Review.edit_and_approve(0, attributes: { "state" => "NJ" }, by: BY)
    assert_match "no longer exists; refresh the queue", result.errors.join
  end

  test "a rejection whose proposal can't be retired is undone, so it can be retried" do
    c = candidate("organization", { "name" => "Imaginary Fission Co" })
    run_stage("match")
    failing = Class.new(DataQuality::DirectoryClient) do
      def decide_fact(*, **) = DataQuality::DirectoryClient::WriteResult.new(ref: nil, errors: [ "database busy" ])
    end.new

    result = Review.reject([ c.id ], by: BY, directory: failing).sole

    assert_equal [ "database busy" ], result.errors
    assert c.reload.status_matched?, "still open"
    assert Review.reject([ c.id ], by: BY).sole.ok?, "a retry works"
  end

  test "bulk approval is one transaction: an unexpected error publishes none of the batch" do
    a = candidate("organization", { "name" => "Alpha Fission Co" })
    b = candidate("organization", { "name" => "Beta Fission Co" })
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)
    second_fails = Class.new(DataQuality::DirectoryClient) do
      def write_fact(candidate, **)
        raise "connection lost" if candidate.payload["name"].start_with?("Beta")

        super
      end
    end.new

    assert_raises(RuntimeError) { Review.approve([ a.id, b.id ], by: BY, directory: second_fails) }

    assert [ a, b ].all? { |x| x.reload.status_matched? }
    assert Organization.find(a.subject_id).pending?, "a wasn't published either"
  end

  # ---- directory facts

  def seed_owns_link(source: sources(:nrc))
    link = FacilityRelationship.create!(organization: organizations(:westinghouse), facility: facilities(:vogtle),
      relationship_type: "owns")
    Evidence.create!(subject: link, source:, quote: "Vogtle is operated for its owners", found_by: "human")
    link
  end

  test "lists pending directory facts with their evidence's source, leaving out ones a candidate covers" do
    link = seed_owns_link

    fact = Review.pending_facts(kind: "facility_relationship").sole

    assert_equal [ "FacilityRelationship", link.id ], [ fact.type, fact.id ]
    assert_equal "owns", fact.attributes[:relationship_type]
    assert_equal [ sources(:nrc).url, "Vogtle is operated for its owners", "human" ],
      [ fact.evidence.sole.source.url, fact.evidence.sole.quote, fact.evidence.sole.found_by ]

    Candidate.create!(source: @source, kind: "facility_relationship", payload: {}, status: "needs_review",
      subject_type: "FacilityRelationship", subject_id: link.id)
    assert_empty Review.pending_facts(kind: "facility_relationship"), "shown in the candidate queue instead"
  end

  test "a page of pending facts reads past ones candidates cover" do
    covered = [ seed_owns_link,
      FacilityRelationship.create!(organization: organizations(:terrapower), facility: facilities(:vogtle), relationship_type: "owns") ]
    uncovered = FacilityRelationship.create!(organization: organizations(:westinghouse), facility: facilities(:vogtle),
      relationship_type: "operates")
    covered.each do |link|
      Candidate.create!(source: @source, kind: "facility_relationship", payload: {}, status: "needs_review",
        subject_type: "FacilityRelationship", subject_id: link.id)
    end

    assert_equal [ uncovered.id ], Review.pending_facts(kind: "facility_relationship", limit: 2).map(&:id)
  end

  test "approving a pending fact (with an edit), then unpublishing and republishing it, all in its history" do
    link = seed_owns_link

    assert Review.approve_fact(type: "FacilityRelationship", id: link.id, by: BY, attributes: { ownership_pct: 45.7 },
      reason: "Checked the annual report").ok?
    assert_equal [ "verified", BY, 45.7 ], [ link.reload.verification_status, link.verified_by, link.ownership_pct.to_f ]

    assert Review.unpublish(type: "FacilityRelationship", id: link.id, by: BY, reason: "Ownership changed").ok?
    assert link.reload.unpublished?
    assert_not_includes FacilityRelationship.published, link

    assert Review.approve_fact(type: "FacilityRelationship", id: link.id, by: BY, reason: "Confirmed again").ok?
    assert link.reload.verified?

    history = Review.history(type: "FacilityRelationship", id: link.id)
    assert_equal %w[verified unpublished verified], history.map(&:to_status).reverse
    assert_equal [ "Confirmed again", "Ownership changed", "Checked the annual report" ], history.map(&:reason)
  end

  test "rejecting a pending fact; a slug can't be edited here" do
    link = seed_owns_link

    assert Review.reject_fact(type: "FacilityRelationship", id: link.id, by: BY, reason: "Not an owner").ok?
    assert link.reload.rejected?
    assert_match "can't edit slug", Review.approve_fact(type: "Organization", id: organizations(:terrapower).id, by: BY,
      attributes: { slug: "x" }).errors.join
    assert_match "can't edit organization_id", Review.approve_fact(type: "FacilityRelationship", id: link.id, by: BY,
      attributes: { organization_id: organizations(:terrapower).id }).errors.join, "a published link can't be moved"
  end

  test "a link whose company or plant is still in review can't be approved, alone or in bulk" do
    other = FacilityRelationship.create!(organization: organizations(:westinghouse), facility: facilities(:vogtle),
      relationship_type: "operates", verification_status: "verified", verified_by: BY)
    open_end = Candidate.create!(source: @source, kind: "facility_relationship", quote: "Nine Mile Point 1 | ...",
      payload: { "organization" => { "name" => "Constellation" }, "facility" => { "name" => "Nine Mile Point 1" },
        "relationship_type" => "operates" },
      status: "needs_review", notes: "facility: no exact match for \"Nine Mile Point 1\"",
      ai_recommendation: "recommend_publish", ai_source_sha256: @source.content_sha256)

    single = Review.approve([ open_end.id ], by: BY).sole
    bulk = Review.approve([ open_end.id ], by: BY, only_recommended: true).sole

    assert_equal [ "nothing was approved: which plant “Nine Mile Point 1” is isn't settled yet. Settle that first (Same as…, or Data Quality), then approve it" ],
      single.errors
    assert_not bulk.ok?
    assert open_end.reload.status_needs_review?, "left for a person"
    assert_empty other.reload.evidence, "no quote added to another link"
  end

  # ---- what Approve all may take (16 Oct: an approve-all replaced hand-written descriptions)

  test "a recommended claim on a record a person decided waits for Data Quality: never in Approve all, nor approved in bulk" do
    decided = Organization.create!(name: "Hand Written Co", description: "Written by a person.", verification_status: "verified", verified_by: BY)
    Evidence.create!(subject: decided, source: @source, quote: "Hand Written Co", found_by: "human")
    on_decided = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Hand Written Co", "description" => "1 award, 2021" },
      quote: "Hand Written Co", status: "matched", subject_type: "Organization", subject_id: decided.id)
    fresh = candidate("organization", { "name" => "Fresh Fission Co" }, quote: "Fresh Fission Co")
    @source.update!(content_text: "Hand Written Co Fresh Fission Co")
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)
    on_decided.update!(ai_recommendation: "recommend_publish", status: "matched") # as the verifier left it on the night

    assert_equal [ fresh.id ], Review.safe_ids
    assert_equal "it would change a record a person decided", Review.candidate(on_decided.id).held

    result = Review.approve([ on_decided.id ], by: BY, only_recommended: true).sole
    assert_match "waits for Data Quality", result.errors.sole
    assert_equal "Written by a person.", decided.reload.description
    assert Review.approve([ on_decided.id ], by: BY).sole.ok?, "on its own, a person can still take it"
  end

  test "a record a person took off or rejected holds its claims too, so a bulk approval never puts it back" do
    gone = Organization.create!(name: "Taken Off Co", verification_status: "verified", verified_by: BY)
    gone.unpublish!(by: BY, reason: "Not nuclear")
    claim = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Taken Off Co" }, quote: "Taken Off Co",
      status: "matched", subject_type: "Organization", subject_id: gone.id, ai_recommendation: "recommend_publish")

    assert_equal "it would change a record a person decided", Review.candidate(claim.id).held
    assert_not_includes Review.safe_ids, claim.id
    assert_match "waits for Data Quality", Review.approve([ claim.id ], by: BY, only_recommended: true).sole.errors.sole
    assert gone.reload.unpublished?
  end

  test "a recommended claim not attached to a record yet waits, so approving can't land on a decided record by its name" do
    decided = Organization.create!(name: "Named Co", description: "A person's.", verification_status: "verified", verified_by: BY)
    unattached = candidate("organization", { "name" => "Named Co", "description" => "The crawler's." }, quote: "Named Co")
    @source.update!(content_text: "Named Co")
    run_stage("verify", verifier: Recommend.new) # verified without a match run: no record attached
    unattached.update!(ai_recommendation: "recommend_publish")

    assert_nil unattached.reload.subject_id
    assert_not_includes Review.safe_ids, unattached.id
    assert_match "waits for Data Quality: it isn't attached", Review.approve([ unattached.id ], by: BY, only_recommended: true).sole.errors.sole
    assert_equal "A person's.", decided.reload.description
  end

  test "a source's first batch waits for Data Quality; later batches are approved in bulk as before" do
    first_run = CrawlRun.create!(stage: "extract", source_kind: "dummy", status: "succeeded", started_at: 2.days.ago)
    later_run = CrawlRun.create!(stage: "extract", source_kind: "dummy", status: "succeeded", started_at: 1.day.ago)
    first = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "First Batch Co" }, quote: "First Batch Co", crawl_run: first_run)
    later = Candidate.create!(source: @source, kind: "organization", payload: { "name" => "Later Batch Co" }, quote: "Later Batch Co", crawl_run: later_run)
    @source.update!(content_text: "First Batch Co Later Batch Co")
    run_stage("match")
    run_stage("verify", verifier: Recommend.new)

    assert_equal [ later.id ], Review.safe_ids
    assert_equal "it's from this source's first batch", Review.candidate(first.id).held
  end
end
