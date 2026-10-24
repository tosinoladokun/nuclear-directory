require "test_helper"

# "Same as…" (#391): a waiting claim whose company is still a question is
# settled in one click, then goes through match and verify again; nothing
# is approved here.
class Admin::CandidateSettlesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:admin)
    @source = Source.create!(url: "https://www.energy.gov/settle.html", source_kind: "web_page", crawl_status: "ok", content_sha256: "sha",
      content_text: "Acme funds GENERAL ATOMICS.")
    @acme = Organization.create!(name: "Acme Fission").tap { |c| c.verify!(by: "human:tosin") }
    @ga = Organization.create!(name: "General Atomics").tap { |c| c.verify!(by: "human:tosin") }
    @matter = Organization.create!(name: "General Matter").tap { |c| c.verify!(by: "human:tosin") }
    @link = Candidate.create!(source: @source, kind: "relationship", status: "needs_review", quote: "Acme funds GENERAL ATOMICS.",
      payload: { "from_organization" => { "name" => "Acme Fission" }, "to_organization" => { "name" => "GENERAL ATOMICS INC" }, "relationship_type" => "funds" },
      notes: %(to_organization: no exact match for "GENERAL ATOMICS INC", but similar: General Matter. Same record, or a new one?))
  end

  def settle_path(candidate = @link, **extra) = admin_candidate_settle_path(candidate.id, **extra)

  test "Checks offers Same as… on it, says which company is the question, and the page shows the similar ones" do
    get admin_checks_path
    assert_select "#claim-#{@link.id} .nd-next-step", /Decide: which company is “GENERAL ATOMICS INC”\? Pick it with Same as…/
    assert_select "#claim-#{@link.id} a.nd-btn--primary[href^=?]", settle_path, text: "Same as…"
    assert_select "#claim-#{@link.id} .nd-wait__actions > :last-child", "Approve"
    assert_select "#claim-#{@link.id} .nd-tag", text: "Waiting for Data Quality", count: 0

    get settle_path
    assert_select "h1", /Which company is “GENERAL ATOMICS INC”\?/
    assert_select "#company-#{@matter.id}", /General Matter/
    get settle_path(q: "atomics")
    assert_select "#company-#{@ga.id} button[aria-label=?]", "Same as General Atomics", "Same as"
  end

  test "Same as on a Research claim: the end is named as that company, its own name kept, matched again, and then it can be approved" do
    assert_enqueued_with(job: DataQuality::RunJob, args: [ "web_page", { only: %w[match verify] } ]) do
      post settle_path, params: { choice: "same", record_id: @ga.id }
    end
    assert_redirected_to admin_checks_path
    @link.reload
    assert_equal "new", @link.status
    [ @acme, @ga ].each { |company| company.aliases.find_or_create_by!(alias: company.name) } # as loaded companies have
    DataQuality::Pipeline.run("web_page", only: %w[match])
    assert @link.reload.subject_id, @link.notes
    assert DataQuality::Review.approve([ @link.id ], by: "human:tosin").sole.ok?
    assert Relationship.find_by!(from_organization: @acme, to_organization: @ga, relationship_type: "funds")
    assert_equal({ "name" => "General Atomics", "aliases" => [ "GENERAL ATOMICS INC" ] }, @link.payload["to_organization"])
    assert_match "tosin settled \"GENERAL ATOMICS INC\" as the same as General Atomics", @link.notes
  end

  test "New company: added not public yet, from the item's source; Subsidiary of adds its link too" do
    post settle_path, params: { choice: "subsidiary", record_id: @ga.id }
    made = Organization.find_by!(name: "GENERAL ATOMICS INC")
    assert_equal "pending", made.verification_status
    assert_equal [ @source.id ], made.evidence.map(&:source_id)
    link = Relationship.find_by!(from_organization: made, to_organization: @ga)
    assert_equal [ "subsidiary_of", "pending" ], [ link.relationship_type, link.verification_status ]
    assert_equal "GENERAL ATOMICS INC", @link.reload.payload.dig("to_organization", "name")

    post settle_path, params: { choice: "new" }
    assert_match "isn't a question any more", flash[:alert]
  end

  test "a company claim with only similar names is attached to the one picked" do
    claim = Candidate.create!(source: @source, kind: "organization", status: "needs_review", quote: "q", payload: { "name" => "General Atomic" },
      notes: %(no exact match for "General Atomic", but similar: General Atomics. Same record, or a new one?))
    post settle_path(claim), params: { choice: "same", record_id: @ga.id }
    claim.reload
    assert_equal [ "matched", "Organization", @ga.id ], [ claim.status, claim.subject_type, claim.subject_id ]
  end

  test "a removed company can't be picked, and a new company that's already listed is refused" do
    @matter.unpublish!(by: "human:tosin", reason: "Not nuclear")
    post settle_path, params: { choice: "same", record_id: @matter.id }
    assert_match "pick the company", flash[:alert]

    Organization.create!(name: "GENERAL ATOMICS INC")
    post settle_path, params: { choice: "new" }
    assert_match "is in the directory already; pick it with Same as", flash[:alert]
    assert_equal "needs_review", @link.reload.status
  end

  test "Same as refuses a name that's already another company's other name; New and Subsidiary use the item's own quote" do
    OrganizationAlias.create!(organization: @matter, alias: "GENERAL ATOMICS INC")
    post settle_path, params: { choice: "same", record_id: @ga.id }
    assert_match "is already General Matter's name or another name", flash[:alert]
    assert_equal "needs_review", @link.reload.status

    OrganizationAlias.delete_all
    post settle_path, params: { choice: "subsidiary", record_id: @ga.id }
    made = Organization.find_by!(name: "GENERAL ATOMICS INC")
    link = Relationship.find_by!(from_organization: made)
    assert_equal [ "Acme funds GENERAL ATOMICS." ], made.evidence.map(&:quote)
    assert_equal [ "Acme funds GENERAL ATOMICS." ], link.evidence.map(&:quote)
    assert_equal "pending", link.verification_status
  end

  test "the settle note survives the match run it queues; a back link outside admin isn't used; a malformed end doesn't break Checks" do
    post settle_path, params: { choice: "same", record_id: @ga.id }
    DataQuality::Pipeline.run("web_page", only: %w[match])
    assert_match "tosin settled \"GENERAL ATOMICS INC\" as the same as General Atomics", @link.reload.notes

    get settle_path(Candidate.create!(source: @source, kind: "relationship", status: "needs_review", quote: "Acme funds GENERAL ATOMICS.",
      payload: { "from_organization" => { "name" => "Acme Fission" }, "to_organization" => { "name" => "GENERAL ATOMICS INC" }, "relationship_type" => "funds" },
      notes: %(to_organization: no exact match for "GENERAL ATOMICS INC")), back: "javascript:alert(1)")
    assert_select "a[href^='javascript']", 0

    Candidate.create!(source: @source, kind: "relationship", status: "needs_review", quote: "Acme funds GA.",
      payload: { "from_organization" => "Acme", "to_organization" => { "name" => "GA" }, "relationship_type" => "funds" },
      notes: %(from_organization: no exact match for "Acme"))
    get admin_checks_path
    assert_response :success
  end

  test "Same as on a claim whose source has a run queues match and verify for it" do
    @source.update_columns(source_kind: "usaspending_doe_awards")
    assert_enqueued_with(job: DataQuality::RunJob, args: [ "usaspending_doe_awards", { only: %w[match verify] } ]) do
      post settle_path, params: { choice: "same", record_id: @ga.id }
    end
    assert_equal "new", @link.reload.status
  end
end
