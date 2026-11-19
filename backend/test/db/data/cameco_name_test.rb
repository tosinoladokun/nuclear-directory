require "test_helper"
load Rails.root.join("db/data/20261118140000_cameco_name.rb")

# PM, 18 Nov 2026: pending company 312 "cameco" becomes "Cameco", Canada, still pending.
class CamecoNameTest < ActiveSupport::TestCase
  setup do
    Organization.find_by(id: 312)&.destroy!
    @company = Organization.create!(id: 312, name: "cameco", verification_status: "pending")
  end

  def run_it = CamecoName.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "renames it, sets Canada, keeps it pending; a rerun changes nothing; a decided one stops it" do
    run_it
    assert_equal [ "Cameco", "CA", "pending" ], @company.reload.values_at(:name, :country_code, :verification_status)
    assert_match "already", run_it.output.sole
    @company.update_columns(name: "cameco", verification_status: "rejected")
    assert_raises(RuntimeError) { run_it }
  end
end
