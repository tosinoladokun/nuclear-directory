require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #548 option a: Data Quality's agent settles company claims through a
# token-only API; nothing it does publishes, and each action can be undone.
class Api::DqMatchingTest < ActionDispatch::IntegrationTest
  TOKEN = "dq-test-token".freeze

  setup do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    @holtec = Organization.create!(name: "Holtec International", verification_status: "verified", verified_by: "human:tosin")
    @holtec.aliases.create!(alias: "Holtec International")
    @page = Source.create!(url: "https://www.nrc.gov/test/dq.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: "Licensee: Holtec. Licensee: Fresh Fission LLC. Licensee: Child Fission.")
  end

  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  def claim(name, quote: "Licensee: #{name}.", **payload) = Candidate.create!(source: @page, kind: "organization", status: "needs_review",
    payload: { "name" => name, **payload }, quote:, notes: %(no exact match for "#{name}"))
  def act(*rows, token: TOKEN) = post(api_dq_matching_path, params: { actions: rows }, as: :json, headers: { "Authorization" => "Bearer #{token}" })
  def results = response.parsed_body["results"]

  test "no token configured, or a malformed digest: the endpoint doesn't exist" do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    act({ id: 1, action: "close", reason: "x" })
    assert_response :not_found
    ENV["DQ_AGENT_TOKEN_DIGEST"] = "not-a-digest"
    act({ id: 1, action: "close", reason: "x" })
    assert_response :not_found
  end

  test "a wrong, missing or cookie-only request is refused, without echoing anything" do
    act({ id: 1, action: "close", reason: "x" }, token: "wrong")
    assert_response :unauthorized
    assert_equal({ "error" => "unauthorized" }, response.parsed_body)
    assert_not_includes response.body, ENV["DQ_AGENT_TOKEN_DIGEST"]
    post api_dq_matching_path, params: { actions: [] }, as: :json
    assert_response :unauthorized
    sign_in_as users(:admin)
    post api_dq_matching_path, params: { actions: [] }, as: :json
    assert_response :unauthorized, "an admin's session cookie is never enough"
  end

  test "the rate limit trips before auth, so guessing isn't free" do
    61.times { act({ id: 1, action: "close", reason: "x" }, token: "wrong") }
    assert_response :too_many_requests
  ensure
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  test "the token never appears in the log" do
    log = StringIO.new
    old = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log)
    act({ id: claim("Holtec").id, action: "close", reason: "r" })
    assert_not_includes log.string, TOKEN
  ensure
    Rails.logger = old
  end

  test "a daily cap on new companies, and batches of at most 50" do
    DataQuality::Matching::DAILY_CREATES.times { |i| DqAction.create!(candidate: claim("Cap #{i}"), action: "new", reason: "r", before: {}, by: DataQuality::Matching::BY) }
    act({ id: claim("Fresh Fission LLC").id, action: "new", reason: "r" })
    assert_match "today's limit", results.sole["error"]
    act(*51.times.map { { id: 1, action: "close", reason: "r" } })
    assert_response :unprocessable_content
  end

  test "same_as: a name variant confirms with its source, publishing nothing new; sent again it's a no-op" do
    variant = claim("Holtec")
    act({ id: variant.id, action: "same_as", target: @holtec.slug, reason: "Same company, short name" })
    assert_equal [ true ], results.map { |r| r["ok"] }, results.inspect
    assert_equal [ "confirmed", @holtec.id ], variant.reload.values_at(:status, :subject_id)
    assert Evidence.exists?(subject: @holtec, quote: "Licensee: Holtec.")
    assert_equal [ "Holtec International" ], @holtec.aliases.pluck(:alias), "no alias without add_alias"
    assert_equal DataQuality::Matching::BY, DqAction.sole.by

    act({ id: variant.id, action: "same_as", target: @holtec.id, reason: "again" })
    assert results.sole["ok"]
    assert_equal 1, DqAction.count
  end

  test "same_as with add_alias stays matched, so the new name is a Change for Tosin" do
    variant = claim("Holtec")
    act({ id: variant.id, action: "same_as", target: @holtec.id, reason: "Keep the short name", add_alias: true })
    assert_equal "needs_review", variant.reload.status
    assert_equal "change", DataQuality::Review.inbox_kind(variant)
  end

  test "a target is an id or slug, never a name; unknown or missing is an error, and the claim is left as it was" do
    c = claim("Holtec")
    act({ id: c.id, action: "same_as", target: "Holtec International", reason: "r" }, { id: c.id, action: "same_as", reason: "r" })
    assert_match "no open company", results.first["error"]
    assert_match "give the company", results.second["error"]
    assert_equal "needs_review", c.reload.status
  end

  test "new: a pending company for Tosin's Create; Undo takes it back" do
    c = claim("Fresh Fission LLC")
    act({ id: c.id, action: "new", reason: "A new licensee" })
    company = Organization.find(results.sole["created_ids"].sole)
    assert company.verification_status == "pending"
    assert_equal "dq", DataQuality::Review.inbox_kind(c.reload), "no category yet: Data Quality's"
    give_sourced_role(company)
    assert_equal "new_record", DataQuality::Review.inbox_kind(c.reload)
    assert_includes OwnerInbox.new.sections["new_record"].map { |entry| entry.item.candidate_id }, c.id, "it's in Tosin's inbox"

    post api_dq_matching_undo_path, params: { action_id: DqAction.sole.id }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert response.parsed_body["ok"], response.parsed_body.inspect
    assert_equal [ "needs_review", nil ], c.reload.values_at(:status, :subject_id)
    assert_equal "rejected", company.reload.verification_status
  end

  test "subsidiary_of: a pending company and a pending link naming the parent" do
    c = claim("Child Fission")
    act({ id: c.id, action: "subsidiary_of", target: @holtec.id, reason: "Holtec's unit" })
    assert results.sole["ok"], results.inspect
    link = Relationship.find_by!(relationship_type: "subsidiary_of", to_organization: @holtec)
    assert_equal "pending", link.verification_status
    link_claim = Candidate.find_by!(subject_type: "Relationship", subject_id: link.id)
    assert_equal "Holtec International", link_claim.payload.dig("to_organization", "name")
    assert_equal "new_fact", DataQuality::Review.inbox_kind(link_claim)
  end

  test "close: rejected with the reason; a lead's name stays in Leads" do
    lead = claim("Maybe Fission", lead: true)
    act({ id: lead.id, action: "close", reason: "Trade press only" })
    assert_equal "rejected", lead.reload.status
    assert_match "Trade press only", lead.notes
    assert Lead.exists?(normalized_name: "maybe fission")
  end

  test "a claim already attached or decided is refused" do
    c = claim("Holtec")
    c.update!(status: "matched", subject_type: "Organization", subject_id: @holtec.id)
    act({ id: c.id, action: "close", reason: "r" })
    assert results.sole["ok"], "skipped, not an error"
    assert_match "skipped: it's already attached or decided", results.sole["error"]
    assert_equal 0, DqAction.count
  end

  test "a retried request with the same key applies once; the new company's history says Data Quality proposed it" do
    c = claim("Fresh Fission LLC")
    2.times { act({ id: c.id, action: "new", reason: "A new licensee", request_key: "batch-1-row-1" }) }
    assert_equal 1, DqAction.count
    company = Organization.find(results.sole["created_ids"].sole)
    event = DataQuality::DirectoryClient.new.verification_history(type: "Organization", id: company.id).last
    assert_equal DataQuality::Matching::BY, event.by
  end

  test "Undo refuses once another claim is attached to what it created" do
    c = claim("Fresh Fission LLC")
    act({ id: c.id, action: "new", reason: "A new licensee" })
    company_id = results.sole["created_ids"].sole
    claim("Fresh Fission LLC").update!(status: "matched", subject_type: "Organization", subject_id: company_id)
    assert_match "claimed since", DataQuality::Matching.undo(DqAction.sole.id)
    assert_nil DqAction.sole.undone_at
  end

  test "Undo of a confirmed same_as takes back the quote it added, and the claim waits again" do
    page = Source.create!(url: "https://example.com/holtec", source_kind: "web_page", crawl_status: "ok", content_sha256: "h")
    Evidence.create!(subject: @holtec, source: page, quote: "Holtec International, of Camden.", found_by: "human")
    variant = claim("Holtec")
    act({ id: variant.id, action: "same_as", target: @holtec.id, reason: "Short name" })
    assert_equal "confirmed", variant.reload.status
    assert Evidence.exists?(subject: @holtec, quote: "Licensee: Holtec.")

    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_not Evidence.exists?(subject: @holtec, quote: "Licensee: Holtec."), "its quote is taken back"
    assert Evidence.exists?(subject: @holtec, quote: "Holtec International, of Camden."), "the record's own stays"
    assert_equal [ "needs_review", nil ], variant.reload.values_at(:status, :subject_id)
  end

  test "Undo never rejects a created company another claim now points at" do
    c = claim("Fresh Fission LLC")
    act({ id: c.id, action: "new", reason: "A new licensee" })
    company = Organization.find(results.sole["created_ids"].sole)
    Candidate.create!(source: @page, kind: "organization", status: "matched", payload: { "name" => "Fresh Fission LLC" }, quote: "q",
      subject_type: "Organization", subject_id: company.id)
    assert_match "claimed since", DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal "pending", company.reload.verification_status
    assert_equal "needs_review", c.reload.status
  end

  test "a digest with spaces or capitals still works; actions that aren't a list of objects get a 422" do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = "  #{Digest::SHA256.hexdigest(TOKEN).upcase}\n"
    post api_dq_matching_path, params: { actions: "close everything" }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :unprocessable_content
    post api_dq_matching_path, params: { actions: [ "x" ] }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_response :unprocessable_content
  end

  test "a claim reopened after a close is closed again, not taken for a retry" do
    c = claim("Maybe Fission")
    act({ id: c.id, action: "close", reason: "Not a company" })
    c.update!(status: "new", reviewed_by: nil, reviewed_at: nil)
    act({ id: c.id, action: "close", reason: "Still not a company" })
    assert_equal "rejected", c.reload.status
    assert_equal 2, DqAction.count
  end

  test "Undo refuses once the claim was moved, e.g. by a merge repointing it" do
    other = Organization.create!(name: "Holtec Survivor", verification_status: "verified", verified_by: "human:tosin")
    variant = claim("Holtec", quote: "Licensee: Holtec.")
    act({ id: variant.id, action: "same_as", target: @holtec.id, reason: "r", add_alias: true })
    variant.update_columns(subject_id: other.id)
    assert_match "changed since", DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal other.id, variant.reload.subject_id
  end

  test "a claim Data Quality acted on isn't deleted as stale when its source is read again" do
    c = claim("Fresh Fission LLC")
    act({ id: c.id, action: "close", reason: "r" })
    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal "needs_review", c.reload.status
    stale = DataQuality::Stages::Extract.allocate.send(:stale, @page)
    assert_not_includes stale.pluck(:id), c.id
  end

  test "the agent can never remove a person's citation" do
    page = Source.create!(url: "https://example.com/cited", source_kind: "web_page", crawl_status: "ok", content_sha256: "c")
    row = Evidence.create!(subject: @holtec, source: page, quote: "Cited by hand.", found_by: "human")
    Evidence.create!(subject: @holtec, source: @page, quote: "Licensee: Holtec.", found_by: "crawler")
    result = Directory::FactWriter.remove_evidence(type: "Organization", id: @holtec.id, evidence_id: row.id, source_id: page.id,
      quote: "Cited by hand.", by: DataQuality::Matching::BY, reason: "test")
    assert_match "can't remove a quote a person added", result.errors.join
    assert Evidence.exists?(row.id)
  end

  test "close applies to an unattached link claim too, with Undo; the other actions don't" do
    link = Candidate.create!(source: @page, kind: "relationship", status: "needs_review", quote: "q",
      payload: { "from_organization" => { "name" => "DOE" }, "to_organization" => { "name" => "Urenco" }, "relationship_type" => "funds" })
    act({ id: link.id, action: "same_as", target: @holtec.id, reason: "r" }, { id: link.id, action: "close", reason: "Tosin rejected this link on 24 Oct" })
    assert_match "only close applies", results.first["error"]
    assert results.second["ok"], results.inspect
    assert_equal "rejected", link.reload.status
    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal "needs_review", link.reload.status
  end

  test "same_as on a link's end names it as that record and sends the claim back to match; Undo restores it" do
    ge = Organization.create!(name: "GE Vernova", verification_status: "verified", verified_by: "human:tosin")
    cooper = Facility.create!(name: "Cooper Nuclear Station", nrc_docket: "05000298", verification_status: "verified", verified_by: "human:tosin")
    link = Candidate.create!(source: @page, kind: "facility_relationship", status: "needs_review", quote: "q",
      payload: { "organization" => { "name" => "GE" }, "facility" => { "name" => "Cooper", "nrc_docket" => "05000999" }, "relationship_type" => "vendor_for" })
    act({ id: link.id, action: "same_as", end: "nowhere", target: cooper.id, reason: "r" },
      { id: link.id, action: "same_as", end: "facility", target: cooper.id, reason: "Cooper is docket 05000298" })
    assert_match "isn't an end", results.first["error"]
    assert results.second["ok"], results.inspect
    link.reload
    assert_equal "new", link.status
    assert_equal({ "name" => "Cooper Nuclear Station", "nrc_docket" => "05000298", "aliases" => [ "Cooper" ] }, link.payload["facility"])
    assert_equal [ "Facility", cooper.id ], DqAction.sole.values_at(:target_type, :target_id)

    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal [ "needs_review", "Cooper" ], [ link.reload.status, link.payload.dig("facility", "name") ]

    act({ id: link.id, action: "same_as", end: "organization", target: ge.slug, reason: "GE is GE Vernova" })
    assert results.sole["ok"], results.inspect
    assert_equal "GE Vernova", link.reload.payload.dig("organization", "name")
  end

  test "a daily cap on closes, undone ones included" do
    DataQuality::Matching::DAILY_CLOSES.times { |i| DqAction.create!(candidate: claim("Closed #{i}"), action: "close", reason: "r", before: {}, by: DataQuality::Matching::BY, undone_at: (Time.current if i.zero?)) }
    act({ id: claim("One More").id, action: "close", reason: "r" })
    assert_match "today's limit of 300 closes", results.sole["error"]
  end

  test "settling many ends of one source queues its match once" do
    cooper = Facility.create!(name: "Cooper Nuclear Station", nrc_docket: "05000298", verification_status: "verified", verified_by: "human:tosin")
    links = 3.times.map do |i|
      Candidate.create!(source: @page, kind: "facility_relationship", status: "needs_review", quote: "q#{i}",
        payload: { "organization" => { "name" => "Vendor #{i}" }, "facility" => { "name" => "Cooper" }, "relationship_type" => "vendor_for" })
    end
    assert_enqueued_jobs 1, only: DataQuality::RunJob do
      act(*links.map { |link| { id: link.id, action: "same_as", end: "facility", target: cooper.id, reason: "r" } })
    end
  end

  test "both ends of one claim can be settled in one batch; a site keeps its EIA plant ID" do
    ge = Organization.create!(name: "GE Both Ends", verification_status: "verified", verified_by: "human:tosin")
    site = Facility.create!(name: "Both Ends Site", eia_plant_id: "99123", verification_status: "verified", verified_by: "human:tosin")
    link = Candidate.create!(source: @page, kind: "facility_relationship", status: "needs_review", quote: "q",
      payload: { "organization" => { "name" => "GE" }, "facility" => { "name" => "Both Ends" }, "relationship_type" => "vendor_for" })
    act({ id: link.id, action: "same_as", end: "facility", target: site.id, reason: "r" }, { id: link.id, action: "same_as", end: "organization", target: ge.id, reason: "r" })
    assert results.all? { |r| r["ok"] }, results.inspect
    link.reload
    assert_equal "99123", link.payload.dig("facility", "eia_plant_id")
    assert_equal "GE Both Ends", link.payload.dig("organization", "name"), "the second end was settled, not taken for a retry"
    assert_equal 2, DqAction.count
  end

  test "recommend records Data Quality's verdict on a waiting claim, feeds Yes to all, publishes nothing, and can be undone" do
    pending = Organization.create!(name: "Fresh Fission LLC", verification_status: "pending")
    c = Candidate.create!(source: @page, kind: "organization", status: "matched", payload: { "name" => "Fresh Fission LLC" }, quote: "Licensee: Fresh Fission LLC.",
      subject_type: "Organization", subject_id: pending.id, proposed_subject: true)
    act({ id: c.id, action: "recommend", verdict: "approve", reason: "Named on the NRC list" }, { id: c.id, action: "recommend", verdict: "maybe", reason: "r" })
    assert results.first["ok"], results.inspect
    assert_match "verdict must be", results.second["error"]
    c.reload
    assert_equal [ "approve", "Named on the NRC list", DataQuality::Matching::BY ], c.values_at(:dq_recommendation, :dq_reason, :dq_by)
    assert DataQuality::Recommendations.current?(c)
    assert_equal "pending", pending.reload.verification_status, "nothing publishes"

    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_nil c.reload.dq_recommendation
  end

  test "new on a plant claim proposes a pending plant" do
    c = Candidate.create!(source: @page, kind: "facility", status: "needs_review", quote: "NC State PULSTAR, docket 05000297",
      payload: { "name" => "PULSTAR Reactor", "nrc_docket" => "05000297", "facility_type" => "research_reactor", "state" => "NC" },
      notes: "similar: North Anna")
    act({ id: c.id, action: "new", reason: "A research reactor, not North Anna" })
    assert results.sole["ok"], results.inspect
    plant = Facility.find(results.sole["created_ids"].sole)
    assert_equal [ "pending", "05000297" ], plant.values_at(:verification_status, :nrc_docket)
    assert_equal "new_record", DataQuality::Review.inbox_kind(c.reload)
    assert_includes OwnerInbox.new.sections["new_record"].map { |entry| entry.item.candidate_id }, c.id, "the plant is in Tosin's inbox"
  end

  test "a changed verdict is recorded, not taken for a repeat; the same verdict again is" do
    c = Candidate.create!(source: @page, kind: "organization", status: "needs_review", payload: { "name" => "Verdict Co" }, quote: "q")
    act({ id: c.id, action: "recommend", verdict: "approve", reason: "first" })
    act({ id: c.id, action: "recommend", verdict: "approve", reason: "again" })
    assert_equal 1, DqAction.count
    act({ id: c.id, action: "recommend", verdict: "reject", reason: "Not a company after all" })
    assert results.sole["ok"], results.inspect
    assert_equal [ "reject", "Not a company after all" ], c.reload.values_at(:dq_recommendation, :dq_reason)
    assert_equal 2, DqAction.count
  end

  test "rolling back the recommend migration refuses while verdicts are recorded" do
    c = claim("Rollback Co")
    act({ id: c.id, action: "recommend", verdict: "approve", reason: "r" })
    require Rails.root.join("db/migrate/20261027120000_allow_recommend_dq_actions")
    assert_raises(ActiveRecord::IrreversibleMigration) { AllowRecommendDqActions.new.tap { |m| m.verbose = false }.migrate(:down) }
  end

  test "a claim held by its source reaches Tosin once Data Quality approves it" do
    pending = give_sourced_role(Organization.create!(name: "Held Ceramics Co", verification_status: "pending"))
    # An earlier, decided batch first, so this one isn't the source's first.
    CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 2.days.ago)
      .then { |first| Candidate.create!(source: @page, crawl_run: first, kind: "organization", payload: { "name" => "x" }, quote: "q", status: "rejected") }
    run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    held = Candidate.create!(source: @page, crawl_run: run, kind: "organization", status: "needs_review", quote: "Licensee: Holtec.",
      payload: { "name" => "Held Ceramics Co" }, subject_type: "Organization", subject_id: pending.id, proposed_subject: true,
      ai_recommendation: "needs_review", notes: "Check they're nuclear energy work")
    original = DataQuality::Recommendations.method(:source_hold?)
    DataQuality::Recommendations.define_singleton_method(:source_hold?) { |_candidate| true }
    assert_equal "dq", DataQuality::Review.inbox_kind(held)
    act({ id: held.id, action: "recommend", verdict: "approve", reason: "The award is for advanced reactor systems" })
    assert_equal "new_record", DataQuality::Review.inbox_kind(held.reload)
  ensure
    DataQuality::Recommendations.define_singleton_method(:source_hold?, original) if original
  end

  test "a first-batch claim reaches Tosin once Data Quality approves it" do
    run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    pending = give_sourced_role(Organization.create!(name: "First Batch Reactor Co", verification_status: "pending"))
    first = Candidate.create!(source: @page, crawl_run: run, kind: "organization", status: "matched", quote: "Licensee: Holtec.",
      payload: { "name" => "First Batch Reactor Co" }, subject_type: "Organization", subject_id: pending.id, proposed_subject: true,
      ai_recommendation: "recommend_publish", ai_source_sha256: "sha")
    assert_equal "dq", DataQuality::Review.inbox_kind(first)
    act({ id: first.id, action: "recommend", verdict: "approve", reason: "On the NRC list" })
    assert_equal "new_record", DataQuality::Review.inbox_kind(first.reload)
    inbox = OwnerInbox.new
    assert_includes inbox.sections["new_record"].map { |entry| entry.item.candidate_id }, first.id
    result = DataQuality::Recommendations.accept(inbox.checked_items, by: "human:tosin").sole
    assert result.ok?, result.errors.inspect
    assert_equal "verified", pending.reload.verification_status, "his Yes to all publishes it"
  end

  test "a first-batch claim with no checker verdict shows in Today once Data Quality approves it, with its own Create" do
    run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    pending = give_sourced_role(Organization.create!(name: "No Verdict Reactor Co", verification_status: "pending"))
    c = Candidate.create!(source: @page, crawl_run: run, kind: "organization", status: "matched", quote: "Licensee: Holtec.",
      payload: { "name" => "No Verdict Reactor Co" }, subject_type: "Organization", subject_id: pending.id, proposed_subject: true)
    act({ id: c.id, action: "recommend", verdict: "approve", reason: "On the NRC list" })
    entry = OwnerInbox.new.sections["new_record"].find { |e| e.item.candidate_id == c.id }
    assert entry, "it's in Today"
    assert entry.checked, "Data Quality's first-hand approve counts (#608)"
  end

  test "Data Quality's own new plant shows in Today even from a source's first batch" do
    run = CrawlRun.create!(source_kind: "dummy", stage: "crawl", status: "succeeded", started_at: 1.day.ago)
    c = Candidate.create!(source: @page, crawl_run: run, kind: "facility", status: "needs_review", quote: "PULSTAR, docket 05000297",
      payload: { "name" => "PULSTAR First Batch", "nrc_docket" => "05000297" }, notes: "similar: North Anna")
    act({ id: c.id, action: "new", reason: "A research reactor" })
    assert_includes OwnerInbox.new.sections["new_record"].map { |e| e.item.candidate_id }, c.id
  end

  test "propose_role: a sourced role claim for a company, matched and verified like any claim; Undo takes it back" do
    Role.find_by(key: "reactor_vendor") || Role.create!(key: "reactor_vendor", name: "Reactor vendor")
    act({ action: "propose_role", target: @holtec.id, role: "reactor_vendor", quote: "Holtec designs the SMR-300.",
      source_url: "https://holtecinternational.com/smr", reason: "Holtec's own page" },
      { action: "propose_role", target: @holtec.id, role: "nonsense", quote: "q", source_url: "https://example.com", reason: "r" },
      { action: "propose_role", target: @holtec.id, role: "reactor_vendor", quote: "", source_url: "https://example.com", reason: "r" })
    assert results.first["ok"], results.inspect
    assert_match "isn't a role", results.second["error"]
    assert_match "give the quote", results.third["error"]
    claim = Candidate.find(results.first["id"])
    assert_equal [ "organization_role", "new", "reactor_vendor", "Holtec International" ],
      [ claim.kind, claim.status, claim.payload["role"], claim.payload.dig("organization", "name") ]
    assert_equal "https://holtecinternational.com/smr", claim.source.url

    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal "rejected", claim.reload.status
  end

  test "propose_role: a retry is answered before the cap; Undo refuses after a reopen or when another source supports the role" do
    Role.find_by(key: "reactor_vendor") || Role.create!(key: "reactor_vendor", name: "Reactor vendor")
    row = { action: "propose_role", target: @holtec.id, role: "reactor_vendor", quote: "Holtec designs the SMR-300.",
      source_url: "https://holtecinternational.com/smr", reason: "Holtec's own page", request_key: "role-1" }
    act(row)
    first = results.sole["id"]
    DataQuality::Matching::DAILY_ROLES.times { |i| DqAction.create!(candidate: claim("Cap #{i}"), action: "propose_role", reason: "r", before: {}, by: DataQuality::Matching::BY) }
    act(row)
    assert_equal [ true, first ], results.sole.values_at("ok", "id"), "a retry, not a limit error"

    claim = Candidate.find(first)
    claim.update_columns(reopenings: [ { "by" => "human:tosin" } ])
    assert_match "decided since", DataQuality::Matching.undo(DqAction.find_by!(request_key: "role-1").id)
  end

  test "new takes a company claim out of a wrong match into its own new company; Undo puts it back" do
    power = Organization.create!(name: "Standard Power", verification_status: "verified", verified_by: "human:tosin")
    wrong = Candidate.create!(source: @page, kind: "organization", status: "matched", quote: "Licensee: Fresh Fission LLC.",
      payload: { "name" => "Standard Nuclear, Inc." }, subject_type: "Organization", subject_id: power.id, notes: "Matched by brand")
    act({ id: wrong.id, action: "new", reason: "A TRISO fuel maker, not the data center developer" })
    assert results.sole["ok"], results.inspect
    made = Organization.find(results.sole["created_ids"].sole)
    assert_equal [ "Standard Nuclear, Inc.", "pending" ], made.values_at(:name, :verification_status)
    assert_equal made.id, wrong.reload.subject_id
    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal power.id, wrong.reload.subject_id
    assert_equal "rejected", made.reload.verification_status
  end

  test "Undo of new on a wrong match refuses when the original company was merged away since" do
    power = Organization.create!(name: "Standard Power", verification_status: "verified", verified_by: "human:tosin")
    wrong = Candidate.create!(source: @page, kind: "organization", status: "matched", quote: "Licensee: Fresh Fission LLC.",
      payload: { "name" => "Standard Nuclear, Inc." }, subject_type: "Organization", subject_id: power.id)
    act({ id: wrong.id, action: "new", reason: "A fuel maker" })
    made = Organization.find(results.sole["created_ids"].sole)
    power.update_columns(verification_status: "unpublished")
    assert_match "merged or taken off", DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal made.id, wrong.reload.subject_id
    assert_equal "pending", made.reload.verification_status
  end

  test "propose_fields: sourced values for a published company become one company claim, a Change for Tosin; bad fields are refused" do
    @page.update!(content_text: "Holtec International is headquartered in Camden, New Jersey.")
    act({ action: "propose_fields", target: @holtec.id, fields: { hq_city: "Camden", hq_state: "NJ", short_description: "Spent fuel storage and SMR design" },
      quote: "Holtec International is headquartered in Camden, New Jersey.", source_url: @page.url, reason: "Their own about page" },
      { action: "propose_fields", target: @holtec.id, fields: { name: "Other" }, quote: "q", source_url: @page.url, reason: "r" },
      { action: "propose_fields", target: @holtec.id, fields: { short_description: "x" * 41 }, quote: "q", source_url: @page.url, reason: "r" })
    assert results.first["ok"], results.inspect
    assert_match "only website", results.second["error"]
    assert_match "40 characters at most", results.third["error"]
    claim = Candidate.find(results.first["id"])
    assert_equal({ "name" => "Holtec International", "hq_city" => "Camden", "hq_state" => "NJ", "short_description" => "Spent fuel storage and SMR design" }, claim.payload)
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    assert_equal [ "Organization", @holtec.id ], claim.reload.values_at(:subject_type, :subject_id), claim.notes
    assert_equal "change", DataQuality::Review.inbox_kind(claim)
    assert_nil @holtec.reload.hq_city, "nothing written until Tosin's Yes"
    assert_nil DataQuality::Matching.undo(DqAction.sole.id)
    assert_equal "rejected", claim.reload.status
  end
end
