require "test_helper"

# The deploy's one-time data step for award terms (#256): runs the real file
# in db/data the way bin/deploy-data does, once, and records it.
class BackfillAwardTermsDataTest < ActiveSupport::TestCase
  BY = "human:tosin"
  COLUMNS = %w[award_id recipient_name amount_usd start_date end_date award_type assistance_listing search award_url
    generated_award_id recipient_id description].freeze

  setup do
    doe = Organization.create!(name: "U.S. Department of Energy", verification_status: "verified", verified_by: BY)
    @verified = Relationship.create!(from_organization: doe, to_organization: Organization.create!(name: "X-energy"),
      relationship_type: "funds", verification_status: "verified", verified_by: BY)
    @pending = Relationship.create!(from_organization: doe, to_organization: Organization.create!(name: "Kairos Power"), relationship_type: "funds")
    { @verified => [ "ASST_A", "ASST_B" ], @pending => [ "ASST_C" ] }.each do |link, ids|
      rows = ids.map { |id| [ id, "R", "1000.00", "2024-01-01", "", "assistance", "81.121", "nuclear", "https://www.usaspending.gov/award/#{id}", id, "r", "d" ] }
      source = Source.create!(url: "https://www.usaspending.gov/recipient/#{link.id}/latest", source_kind: "usaspending_doe_awards", crawl_status: "ok",
        content_text: CSV.generate { |csv| csv << COLUMNS; rows.each { |row| csv << row } })
      link.evidence.create!(source:, quote: "row", found_by: "crawler")
    end
  end

  def step = DeployData::Migrations.new(Rails.root.join("db/data")).pending.find { |pending| pending.name == "backfill_award_terms" }

  test "writes each award once, verified only on a verified link, and records the run" do
    ran = nil
    capture_io { ran = DeployData::Migrations.new(Rails.root.join("db/data")).run(step, reason: "deploy abc1234, PR #999", commit: "abc1234") }

    assert_equal [ true, true ], DealTerm.where(link: @verified).map(&:verified?)
    assert DealTerm.find_by!(external_id: "ASST_C").pending?
    assert_includes ran.output, "3 award terms written, 0 already there."
    assert_includes ran.output, "2 on verified links (written verified), 1 on pending links (written pending)."
    assert_match "deploy abc1234, PR #999", DealTerm.find_by!(external_id: "ASST_A").verification_events.last.reason
    assert_equal "human:tosin", DataMigration.find_by!(name: "backfill_award_terms").by
    assert_nil step, "it runs once"
    assert_equal 0, Directory::AwardBackfill.new(by: BY).run(apply: true).written, "a rerun writes nothing"
  end
end
