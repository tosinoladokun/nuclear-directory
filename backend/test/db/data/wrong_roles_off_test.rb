require "test_helper"
load Rails.root.join("db/data/20261120230000_wrong_roles_off.rb")

# Data Quality, 20 Nov 2026: seven role rows that the companies' own pages don't support come off; their companies and
# their other roles stay. The fixtures are decisions made before the read, at a fixed time (the step runs after it).
class WrongRolesOffTest < ActiveSupport::TestCase
  BY = "human:tosin"
  BEFORE = Time.utc(2026, 11, 20, 17, 46)

  setup do
    travel_to Time.utc(2026, 11, 20, 18)
    @rows = WrongRolesOff::ROWS.to_h do |id, (company, key)|
      org = Organization.find_by(name: company) || Organization.create!(name: company, verification_status: "verified", verified_by: BY)
      role = Role.find_by(key:) || Role.create!(key:, name: key.humanize)
      OrganizationRole.find_by(id:)&.destroy!
      [ id, OrganizationRole.create!(id:, organization: org, role:, verification_status: "verified", verified_by: BY, verified_at: BEFORE) ]
    end
    @aalo = Organization.find_by!(name: "Aalo Atomics")
    @kept = OrganizationRole.create!(id: 900_001, organization: @aalo, role: Role.find_or_create_by!(key: "fabrication") { |r| r.name = "Fabrication" },
      verification_status: "verified", verified_by: BY, verified_at: BEFORE)
    VerificationEvent.update_all(created_at: BEFORE)
    travel_to Time.utc(2026, 11, 21, 12)
  end

  def run_it = WrongRolesOff.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "takes off the seven rows with the reason and the deploy; the company and its other role stay; a rerun changes nothing" do
    run_it
    @rows.each_value { |row| assert_equal "unpublished", row.reload.verification_status }
    assert @kept.reload.verified?, "Aalo's other role stays"
    assert @aalo.reload.verified?, "the company stays"
    assert_match "Not stated by the company", VerificationEvent.where(subject: @rows[495]).order(:id).last.reason.to_s
    assert_match "deploy abc1234, PR #1", VerificationEvent.where(subject: @rows[495]).order(:id).last.reason.to_s
    assert_no_difference "VerificationEvent.count" do
      assert(run_it.output.all? { |line| line.include?("already") })
    end
  end

  test "a row that is not the company/role read, or was decided again, is left and said, never a stopped deploy" do
    @rows[497].update_columns(role_id: Role.find_or_create_by!(key: "coolant") { |r| r.name = "Coolant" }.id)
    @rows[506].update_columns(verified_at: Time.utc(2026, 11, 20, 22))
    output = nil
    assert_nothing_raised { output = run_it.output }
    assert_equal "verified", @rows[497].reload.verification_status
    assert_equal "verified", @rows[506].reload.verification_status
    assert_equal "unpublished", @rows[507].reload.verification_status
    assert output.any? { |line| line.include?("left as it is") }
  end

  test "a gone row is skipped" do
    @rows[512].destroy!
    assert_nothing_raised { run_it }
    assert_equal "unpublished", @rows[508].reload.verification_status
  end

  test "a later verification event with an unchanged verified_at (a same-reviewer edit) also counts as decided again" do
    VerificationEvent.create!(subject: @rows[509], to_status: "verified", by: BY, reason: "his own later edit", created_at: Time.utc(2026, 11, 20, 22))
    assert_equal BEFORE, @rows[509].reload.verified_at, "verified_at is unchanged"
    output = nil
    assert_no_difference -> { VerificationEvent.where(subject: @rows[509]).count } do
      output = run_it.output
    end
    assert_equal "verified", @rows[509].reload.verification_status
    assert output.any? { |line| line.include?("was decided again") && line.include?("509") }, output.inspect
    assert_equal "unpublished", @rows[508].reload.verification_status, "the other rows still come off"
  end
end
