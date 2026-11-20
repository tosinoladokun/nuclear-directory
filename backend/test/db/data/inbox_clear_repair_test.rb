require "test_helper"
load Rails.root.join("db/data/20261120210000_inbox_clear_repair.rb")

# Data Quality, 20 Nov 2026: after the inbox clear, a NANO news item is reworded to its non-binding MOU, a webcast notice
# and the non-nuclear Lithios (with its ARPA-E link, award term and quote) come off, and Moltex's mixed HQ is cleared.
# The records look as Data Quality read them in production.
class InboxClearRepairTest < ActiveSupport::TestCase
  BY = "human:tosin"
  READ = Time.utc(2026, 11, 20, 17, 46)

  setup do
    # The fixtures are decisions made BEFORE the step's read (17:46 UTC): created at a fixed earlier time, so the tests
    # don't depend on when they run; the step then runs after the cutoff, as it does at deploy.
    travel_to Time.utc(2026, 11, 20, 18)
    NewsItem.where(id: [ 68, 69 ]).destroy_all
    @sj = NewsItem.create!(id: 69, url: InboxClearRepair::NANO_SJ[:url], title: "NANO Nuclear Energy and SJ Group Establish Collaboration",
      headline: InboxClearRepair::NANO_SJ[:was], published_on: Date.new(2026, 11, 19), publisher: "NANO Nuclear Energy",
      verification_status: "verified", verified_by: BY, verified_at: READ)
    @webcast = NewsItem.create!(id: 68, url: InboxClearRepair::WEBCAST[:url], title: "NANO Nuclear to Hold Fourth Quarter Business Update Webcast",
      headline: "NANO Nuclear to hold fourth-quarter business update webcast", published_on: Date.new(2026, 11, 11), publisher: "NANO Nuclear Energy",
      verification_status: "verified", verified_by: BY, verified_at: READ)
    NewsItem.where(id: [ 19, 34 ]).destroy_all
    @fr = NewsItem.create!(id: 19, url: "https://www.federalregister.gov/documents/2026/10/28/2026-21996/x", title: "Paducah FEIS (Federal Register)", headline: "Final environmental impact statement: Paducah Laser Enrichment Facility",
      published_on: Date.new(2026, 10, 28), publisher: "Federal Register (NRC)", verification_status: "verified", verified_by: BY, verified_at: Time.utc(2026, 11, 2))
    @gle = NewsItem.create!(id: 34, url: InboxClearRepair::PADUCAH_DUPLICATE[:url], title: "NRC Issues Final Environmental Impact Statement for the Paducah Laser Enrichment Facility",
      headline: "NRC issues final environmental impact statement for Paducah facility", published_on: Date.new(2026, 10, 23), publisher: "Global Laser Enrichment",
      verification_status: "verified", verified_by: BY, verified_at: Time.utc(2026, 11, 8))
    @other_news = NewsItem.create!(id: 900_001, url: "https://example.com/n", title: "Other", headline: "Other nuclear news", published_on: Date.new(2026, 11, 19),
      publisher: "Other", verification_status: "verified", verified_by: BY, verified_at: READ)

    pin = InboxClearRepair::LITHIOS
    [ pin[:company_id], pin[:funder_id], InboxClearRepair::MOLTEX[:id] ].each { |id| Organization.find_by(id:)&.destroy! }
    @arpa = Organization.create!(id: pin[:funder_id], name: "Advanced Research Projects Agency-Energy", verification_status: "verified", verified_by: BY)
    @lithios = Organization.create!(id: pin[:company_id], name: "Lithios", verification_status: "pending")
    Relationship.find_by(id: pin[:link_id])&.destroy!
    @link = Relationship.create!(id: pin[:link_id], from_organization: @arpa, to_organization: @lithios, relationship_type: "funds",
      verification_status: "verified", verified_by: BY, verified_at: Time.utc(2026, 11, 20, 20, 18))
    DealTerm.find_by(id: pin[:term_id])&.destroy!
    @term = DealTerm.create!(id: pin[:term_id], link: @link, term_type: "award", external_id: "x", amount_usd: pin[:amount], starts_on: Date.new(2026, 4, 6),
      verification_status: "verified", verified_by: BY, verified_at: Time.utc(2026, 11, 20, 20, 18))
    Source.find_by(id: pin[:evidence_source_id])&.destroy!
    page = Source.create!(id: pin[:evidence_source_id], url: "https://arpa-e.energy.gov/x", source_kind: "web_page", crawl_status: "ok")
    Evidence.find_by(id: pin[:evidence_id])&.destroy!
    @quote = Evidence.create!(id: pin[:evidence_id], subject: @link, source: page, quote: pin[:evidence_quote], found_by: "crawler")
    @other_link = Relationship.create!(id: 900_001, from_organization: @arpa, to_organization: Organization.create!(id: 900_001, name: "Marathon Fusion"), relationship_type: "funds",
      verification_status: "verified", verified_by: BY)

    @moltex = Organization.create!(id: InboxClearRepair::MOLTEX[:id], name: "Moltex Energy", legal_name: "Moltex Energy Limited", hq_city: "Wilmington",
      hq_state: "DE", verification_status: "verified", verified_by: BY, verified_at: Time.utc(2026, 11, 20, 19, 35))
    # Every decision above was made before the read; the step runs after the cutoff, as it does at deploy.
    VerificationEvent.update_all(created_at: READ)
    travel_to Time.utc(2026, 11, 21, 12)
  end

  def run_it = InboxClearRepair.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "rewords the NANO item, takes off the webcast and the Lithios link, term and quote, rejects Lithios, clears Moltex's HQ" do
    run_it
    assert_equal InboxClearRepair::NANO_SJ[:headline], @sj.reload.headline
    assert_match "non-binding memorandum of understanding", @sj.summary
    assert_equal "verified", @sj.verification_status
    assert_equal "unpublished", @webcast.reload.verification_status
    assert_equal "unpublished", @gle.reload.verification_status
    assert_match "Duplicate of news item 19", VerificationEvent.where(subject: @gle).order(:id).last.reason.to_s
    assert @fr.reload.verified?, "the Federal Register item stays"
    assert_equal "rejected", @lithios.reload.verification_status
    assert_equal "unpublished", @link.reload.verification_status
    assert_equal "unpublished", @term.reload.verification_status
    assert_not Evidence.exists?(@quote.id)
    assert_nil @moltex.reload.hq_city
    assert_nil @moltex.hq_state
    assert_equal "Moltex Energy Limited", @moltex.legal_name
    assert @other_news.reload.verified?
    assert @other_link.reload.verified?
    assert_match "deploy abc1234, PR #1", VerificationEvent.where(subject: @webcast).order(:id).last.reason.to_s
  end

  test "a rerun changes nothing" do
    run_it
    assert_no_difference [ "VerificationEvent.count", "Evidence.count" ] do
      assert(run_it.output.all? { |line| line.match?(/already|nothing to clear|no HQ/) }, run_it.output.inspect)
    end
  end

  test "records that are not as read are left and said, never a stopped deploy" do
    @sj.update_columns(headline: "Something else")
    @webcast.update_columns(url: "https://example.com/other")
    @link.update_columns(to_organization_id: Organization.create!(id: 900_002, name: "Someone Else").id)
    @moltex.update_columns(hq_city: "Saint John", hq_state: "NB")
    output = nil
    assert_nothing_raised { output = run_it.output }
    assert_equal "Something else", @sj.reload.headline
    assert_equal "verified", @webcast.reload.verification_status
    assert_equal "verified", @link.reload.verification_status
    assert_equal "verified", @term.reload.verification_status, "a changed link keeps its term"
    assert Evidence.exists?(@quote.id), "and its quote"
    assert_equal "Saint John", @moltex.reload.hq_city
    assert output.any? { |line| line.include?("left as it is") }
  end

  test "a record decided again since the read is left alone" do
    @webcast.update_columns(verified_at: Time.utc(2026, 11, 20, 22))
    @moltex.update_columns(verified_at: Time.utc(2026, 11, 20, 22))
    run_it
    assert_equal "verified", @webcast.reload.verification_status
    assert_equal "Wilmington", @moltex.reload.hq_city
  end

  test "Lithios already decided by a person is left as it is" do
    @lithios.update_columns(verification_status: "verified")
    run_it
    assert_equal "verified", @lithios.reload.verification_status
  end

  test "a link decided again since the read keeps its term and quote" do
    @link.update_columns(verified_at: Time.utc(2026, 11, 20, 22))
    run_it
    assert_equal "verified", @link.reload.verification_status
    assert_equal "verified", @term.reload.verification_status
    assert Evidence.exists?(@quote.id)
  end

  test "a quote that changed on the link is not deleted" do
    @quote.update_columns(quote: "A replacement quote")
    run_it
    assert_equal "unpublished", @link.reload.verification_status
    assert Evidence.exists?(@quote.id), "the replacement stays"
  end

  test "a same-reviewer edit of the NANO item after the read (it keeps verified_at) is left alone" do
    Directory::FactWriter.write("news_item", { id: 69, summary: "Tosin's own correction." },
      verification: { status: "verified", by: BY, reason: "his edit" }, protect_human_verified: false)
    @sj.update_columns(verified_at: READ)
    run_it
    assert_equal "Tosin's own correction.", @sj.reload.summary
    assert_equal InboxClearRepair::NANO_SJ[:was], @sj.headline
  end
end
