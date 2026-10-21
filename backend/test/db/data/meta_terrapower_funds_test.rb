require "test_helper"
load Rails.root.join("db/data/20261018120000_meta_terrapower_funds.rb")

# Tosin, 17 Oct 2026: Meta–TerraPower is funding, so the old power-deal link
# (34) comes off; the seed writes the funds link.
class MetaTerrapowerFundsTest < ActiveSupport::TestCase
  setup do
    meta = Organization.create!(name: "Meta", slug: "meta-test", verification_status: "verified", verified_by: "human:tosin")
    terrapower = Organization.create!(name: "TerraPower", slug: "terrapower-test", verification_status: "verified", verified_by: "human:tosin")
    @link = Relationship.create!(id: MetaTerrapowerFunds::LINK_ID, from_organization: meta, to_organization: terrapower,
      relationship_type: "offtake_with", description: "Agreement (Jan 2026)", verification_status: "verified", verified_by: "human:tosin")
  end

  def run_it = MetaTerrapowerFunds.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "takes the power-deal link off as Tosin's decision, and a rerun changes nothing" do
    migration = run_it

    assert @link.reload.unpublished?
    event = VerificationEvent.where(subject: @link).order(:id).last
    assert_equal [ "unpublished", "human:tosin" ], [ event.to_status, event.by ]
    assert_match "Re-typed as Meta funds TerraPower", event.reason
    assert_match "Took off link", migration.output.sole

    assert_no_difference -> { VerificationEvent.count } do
      assert_match "already unpublished", run_it.output.sole
    end
  end

  test "stops when link 34 is no longer Meta's power deal with TerraPower" do
    @link.update_columns(relationship_type: "funds")

    error = assert_raises(RuntimeError) { run_it }
    assert_match "no longer Meta offtake_with TerraPower", error.message
    assert @link.reload.verified?
  end
end
