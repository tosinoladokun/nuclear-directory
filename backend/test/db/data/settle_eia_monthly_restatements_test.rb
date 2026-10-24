require "test_helper"
load Rails.root.join("db/data/20261024170000_settle_eia_monthly_restatements.rb")

# A new EIA monthly file's claims that restate an approved unit close on
# their own, with the new file's evidence; one that differs keeps waiting.
class SettleEiaMonthlyRestatementsTest < ActiveSupport::TestCase
  setup do
    @unit = Facility.create!(name: "Hope Creek 1", nrc_docket: "05000354", state: "NJ", capacity_mw: "1227.40", latitude: 39.467528,
      verification_status: "verified", verified_by: "human:tosin")
    august = Source.create!(url: "https://www.eia.gov/test/august_generator2026.xlsx", source_kind: "eia_generators", crawl_status: "ok",
      content_text: "Hope Creek,1,NJ,1227.4,39.4675")
    @september = Source.create!(url: "https://www.eia.gov/test/september_generator2026.xlsx", source_kind: "eia_generators", crawl_status: "ok",
      content_text: "Hope Creek,1,NJ,1227.4,39.4675\nHope Creek,1,NJ,1300,39.4675")
    Evidence.create!(subject: @unit, source: august, quote: "Hope Creek,1,NJ,1227.4,39.4675", found_by: "crawler")
    claim = ->(capacity, quote) do
      Candidate.create!(source: @september, kind: "facility", status: "needs_review", subject_type: "Facility", subject_id: @unit.id, quote:,
        payload: { "identify" => { "name" => "Hope Creek", "state" => "NJ", "unit" => "1" }, "capacity_mw" => capacity, "latitude" => "39.4675" })
    end
    @same = claim.("1227.4", "Hope Creek,1,NJ,1227.4,39.4675")
    @different = claim.("1300", "Hope Creek,1,NJ,1300,39.4675")
  end

  def run_it = SettleEiaMonthlyRestatements.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "closes the restatements with the new file's evidence, keeps a difference waiting, and a rerun closes nothing" do
    migration = run_it
    assert @same.reload.status_confirmed?, @same.notes
    assert @different.reload.status_needs_review?
    assert Evidence.exists?(subject: @unit, source: @september)
    assert_match "Closed 1 EIA monthly claims", migration.output.sole

    assert_match "Closed 0", run_it.output.sole
  end
end
