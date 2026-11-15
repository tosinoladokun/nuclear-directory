require "test_helper"
load Rails.root.join("db/data/20261115120000_non_nuclear_repair.rb")

# PM and Data Quality, 15 Nov 2026: a Mars news item and three non-nuclear DOE funds links come off, each link with
# its award term and its quote. The records look as Data Quality read them in production.
class NonNuclearRepairTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @doe = Organization.create!(name: "U.S. Department of Energy", verification_status: "verified", verified_by: BY)
    @page = Source.create!(url: "https://www.usaspending.gov/recipient/x", source_kind: "web_page", crawl_status: "ok")
    @links = NonNuclearRepair::LINKS.to_h do |id, pin|
      Organization.find_by(id: pin[:company_id])&.destroy!
      company = Organization.create!(id: pin[:company_id], name: pin[:company], verification_status: "pending")
      Relationship.find_by(id:)&.destroy!
      link = Relationship.create!(id:, from_organization: @doe, to_organization: company, relationship_type: "funds", verification_status: "verified", verified_by: BY)
      DealTerm.create!(id: pin[:term_id], link:, term_type: "award", external_id: "DE-#{id}", amount_usd: 1_000_000, starts_on: Date.new(2024, 9, 1), verification_status: "verified", verified_by: BY)
      Evidence.find_by(id: pin[:evidence_id])&.destroy!
      Evidence.create!(id: pin[:evidence_id], subject: link, source: @page, quote: "award #{id}", found_by: "crawler")
      [ id, link ]
    end
    NewsItem.find_by(id: 37)&.destroy!
    @news = NewsItem.create!(id: 37, url: NonNuclearRepair::NEWS[:url], title: "Rubies on Mars?", headline: "Perseverance instruments study Mars\u2019s ancient rock record",
      published_on: Date.new(2026, 11, 9), publisher: "NASA", verification_status: "verified", verified_by: BY, verified_at: Time.current)
    @other = Relationship.create!(from_organization: @doe, to_organization: Organization.create!(name: "Deep Isolation"), relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
  end

  def run_it = NonNuclearRepair.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "takes off the news item and each link with its term, removes its quote; others stay; a rerun changes nothing" do
    run_it
    assert_equal "unpublished", @news.reload.verification_status
    NonNuclearRepair::LINKS.each do |id, pin|
      assert_equal "unpublished", @links[id].reload.verification_status
      assert_equal "unpublished", DealTerm.find(pin[:term_id]).verification_status
      assert_not Evidence.exists?(pin[:evidence_id])
      assert Organization.find(pin[:company_id]).verification_status == "pending", "the company stays as it is"
    end
    assert @other.reload.verified?, "a nuclear funds link stays"
    assert_equal BY, VerificationEvent.where(subject: @links[229]).order(:id).last.by

    assert_no_difference [ "VerificationEvent.count", "Evidence.count" ] do
      assert(run_it.output.all? { |line| line.include?("already") })
    end
  end

  test "stops when a link is no longer DOE funds that company, or was decided differently since" do
    @links[230].update_columns(to_organization_id: Organization.create!(name: "Someone Else").id)
    assert_raises(RuntimeError) { run_it }
    @links[230].update_columns(to_organization_id: 269, verification_status: "rejected")
    error = assert_raises(RuntimeError) { run_it }
    assert_match "is rejected, not verified", error.message
  end
end
