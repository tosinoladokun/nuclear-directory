require "test_helper"
load Rails.root.join("db/data/20261112120000_dq_rejects_repair.rb")

# Data Quality, 12 Nov 2026: three wrong company values back to their sources, and a non-nuclear news item off.
class DqRejectsRepairTest < ActiveSupport::TestCase
  setup do
    org = ->(name, **attrs) { Organization.create!(name:, verification_status: "verified", verified_by: "human:tosin", **attrs) }
    @framatome = org.("Framatome", hq_city: "Lynchburg", hq_state: "VA", country_code: "FR")
    @bwxt = org.("BWX Technologies", legal_name: "BWX Technologies. Inc.")
    @cti = org.("Container Technologies Industries", legal_name: "Inc.")
    @news = NewsItem.create!(id: DqRejectsRepair::NEWS_ID, url: "https://vistra.example/interns", title: DqRejectsRepair::NEWS_TITLE,
      published_on: Date.new(2026, 11, 1), publisher: "Vistra", verification_status: "verified", verified_by: "human:tosin", verified_at: Time.current)
  end

  def run_it = DqRejectsRepair.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "fixes each value as Tosin's decision and takes the news item off; a rerun changes nothing" do
    run_it
    assert_equal [ "Courbevoie", nil, "FR" ], [ @framatome.reload.hq_city, @framatome.hq_state, @framatome.country_code ]
    assert_equal "BWX Technologies, Inc.", @bwxt.reload.legal_name
    assert_equal "Container Technologies Industries, LLC", @cti.reload.legal_name
    assert @bwxt.verified?, "still published"
    assert_equal "unpublished", @news.reload.verification_status

    assert_no_difference -> { VerificationEvent.count } do
      output = run_it.output
      assert_equal 3, output.count { |line| line.end_with?("already fixed") }
      assert_match "already off", output.last
    end
  end

  test "stops when a record no longer has the value read on 12 Nov (the US arm in Lynchburg stays)" do
    @framatome.update_columns(country_code: "US")
    error = assert_raises(RuntimeError) { run_it }
    assert_match "Framatome no longer has the value read on 12 Nov", error.message
    assert_equal "Lynchburg", @framatome.reload.hq_city
  end
end
