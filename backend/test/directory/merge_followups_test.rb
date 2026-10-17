require "test_helper"
require_relative "../data_quality/support/dummy_plugin"

# After a merge (#325): the admin's preview takes no locks, and a claim a
# crawl attached to the merged-away record follows it to the one kept.
class Directory::MergeFollowupsTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @into = Organization.create!(name: "Kept Co", verification_status: "verified", verified_by: BY)
    @from = Organization.create!(name: "Duplicate Co", verification_status: "verified", verified_by: BY)
  end

  def claim(subject) = Candidate.create!(source: sources(:press_release), kind: "organization", quote: "q", status: "matched",
    payload: { "name" => subject.name }, subject_type: subject.class.name, subject_id: subject.id)

  test "a claim attached to a merged-away record after the merge moves to the one kept" do
    assert Directory::FactWriter.merge_organization(from_id: @from.id, into_id: @into.id, by: BY).ok?
    late = claim(@from)
    decided = claim(@from).tap { |c| c.update!(status: "rejected") }

    assert_equal 1, Directory::FactWriter.repoint_merged_claims
    assert_equal @into.id, late.reload.subject_id
    assert_not late.proposed_subject
    assert_equal @from.id, decided.reload.subject_id, "a decided claim stays as it was decided"
  end

  test "it follows a merge of a merge, and leaves a record taken off for another reason" do
    final = Organization.create!(name: "Final Co", verification_status: "verified", verified_by: BY)
    assert Directory::FactWriter.merge_organization(from_id: @from.id, into_id: @into.id, by: BY).ok?
    assert Directory::FactWriter.merge_organization(from_id: @into.id, into_id: final.id, by: BY).ok?
    late = claim(@from)
    removed = Organization.create!(name: "Removed Co", verification_status: "verified", verified_by: BY)
    removed.unpublish!(by: BY, reason: "Not nuclear")
    stays = claim(removed)

    Directory::FactWriter.repoint_merged_claims

    assert_equal final.id, late.reload.subject_id
    assert_equal removed.id, stays.reload.subject_id
  end

  test "match moves them at the end of its run" do
    assert Directory::FactWriter.merge_organization(from_id: @from.id, into_id: @into.id, by: BY).ok?
    late = claim(@from)

    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "match")

    assert_equal @into.id, late.reload.subject_id
  end

  test "it follows a long chain of merges to the end" do
    chain = [ @from, @into, *(1..6).map { |n| Organization.create!(name: "Link #{n} Co", verification_status: "verified", verified_by: BY) } ]
    chain.each_cons(2) { |from, into| assert Directory::FactWriter.merge_organization(from_id: from.id, into_id: into.id, by: BY).ok? }
    late = claim(@from)

    Directory::FactWriter.repoint_merged_claims

    assert_equal chain.last.id, late.reload.subject_id
  end
end

# The preview with another session holding the rows, as a merge or an
# approval in another request would. Its records are committed, so that
# session can see and lock them; the test cleans up after itself.
class Directory::MergePreviewLocksTest < ActiveSupport::TestCase
  self.use_transactional_tests = false
  BY = "human:tosin"

  def other_session
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    PG.connect(host: config[:host], port: config[:port], dbname: config[:database], user: config[:username], password: config[:password])
  end

  test "the preview reads while another session holds both records and their claims locked; the merge would wait" do
    into = Organization.create!(name: "Locked Kept Co", verification_status: "verified", verified_by: BY)
    from = Organization.create!(name: "Locked Duplicate Co", verification_status: "verified", verified_by: BY)
    claim = Candidate.create!(source: sources(:press_release), kind: "organization", quote: "q", status: "matched",
      payload: { "name" => from.name }, subject_type: "Organization", subject_id: from.id)

    other = other_session
    other.exec("BEGIN")
    assert_equal 2, other.exec("SELECT id FROM organizations WHERE id IN (#{from.id}, #{into.id}) FOR UPDATE").ntuples
    assert_equal 1, other.exec("SELECT id FROM candidates WHERE id = #{claim.id} FOR UPDATE").ntuples

    ActiveRecord::Base.connection.execute("SET lock_timeout = '300ms'")
    result, moved = Directory::FactWriter.merge_preview(type: "Organization", from_id: from.id, into_id: into.id)
    assert result.ok?
    assert_equal "1 alias, 1 candidate", moved
    assert_raises(ActiveRecord::LockWaitTimeout, "the merge itself does wait on those locks") do
      Directory::FactWriter.merge_organization(from_id: from.id, into_id: into.id, by: BY)
    end
    assert_equal from.id, claim.reload.subject_id, "nothing moved"
  ensure
    ActiveRecord::Base.connection.execute("SET lock_timeout = 0")
    other&.exec("ROLLBACK")
    other&.close
    ids = [ from&.id, into&.id ].compact
    Candidate.where(id: claim&.id).delete_all
    OrganizationAlias.where(organization_id: ids).delete_all
    VerificationEvent.where(subject_type: "Organization", subject_id: ids).delete_all
    Organization.where(id: ids).delete_all
  end
end
