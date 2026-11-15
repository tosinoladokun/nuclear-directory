require "test_helper"
load Rails.root.join("db/data/20261112120000_dq_rejects_repair.rb")

# Data Quality, 12 Nov 2026: three wrong company values back to their sources, each with its quote, the old values'
# quotes removed, and a non-nuclear news item off. The records look as they do in production.
class DqRejectsRepairTest < ActiveSupport::TestCase
  setup do
    @framatome = company(13, "Framatome", { hq_city: "Lynchburg", hq_state: "VA", country_code: "FR" },
      "hq_city" => "Lynchburg", quote: "Framatome Inc., 3315 Old Forest Road, Lynchburg, VA")
    @bwxt = company(98, "BWXT", { legal_name: "BWX Technologies. Inc." }, "legal_name" => "BWX Technologies. Inc.", quote: "© 2026 BWX Technologies. Inc.")
    @cti = company(96, "Container Technologies Industries", { legal_name: "Container Technologies Industries, Inc." },
      "legal_name" => "Container Technologies Industries, Inc.", quote: "Container Technologies Industries, Inc. builds casks.")
    @news = NewsItem.create!(id: DqRejectsRepair::NEWS_ID, url: DqRejectsRepair::NEWS_URL, title: DqRejectsRepair::NEWS_TITLE,
      headline: "Vistra highlights its 2026 summer internship program", published_on: Date.new(2026, 10, 30), publisher: "Vistra",
      verification_status: "verified", verified_by: "human:tosin", verified_at: Time.current)
  end

  # A published company, and the merged claim Data Quality said no to that put the old value there, with its quote.
  def company(id, name, values, payload)
    quote = payload.delete(:quote)
    Organization.find_by(id:)&.destroy!
    record = Organization.create!(id:, name:, verification_status: "verified", verified_by: "human:tosin", **values)
    page = Source.create!(url: "https://example.com/#{id}", source_kind: "web_page", crawl_status: "ok", content_sha256: "s", content_text: quote)
    Candidate.create!(source: page, kind: "organization", status: "merged", payload: { "name" => name, **payload }, quote:,
      subject_type: "Organization", subject_id: id, dq_recommendation: "reject", dq_reason: "wrong")
    Evidence.create!(subject: record, source: page, quote:, found_by: "crawler")
    record
  end

  def run_it = DqRejectsRepair.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "fixes each value as Tosin's decision with its own quote, removes the old value's quote, takes the news off; a rerun changes nothing" do
    run_it
    assert_equal [ "Courbevoie", nil, "FR" ], [ @framatome.reload.hq_city, @framatome.hq_state, @framatome.country_code ]
    assert_equal "BWX Technologies, Inc.", @bwxt.reload.legal_name
    assert_equal "Container Technologies Industries, LLC", @cti.reload.legal_name
    assert @bwxt.verified?, "still published"
    DqRejectsRepair::COMPANIES.each do |id, fix|
      quotes = Evidence.where(subject_type: "Organization", subject_id: id).includes(:source).map { |row| [ row.source.url, row.quote, row.fields.sort, row.found_by ] }
      assert_equal [ [ fix[:url], fix[:quote], fix[:fields].sort, "human" ] ], quotes, "company #{id}: its new quote only"
    end
    assert_equal "unpublished", @news.reload.verification_status

    assert_no_difference [ "VerificationEvent.count", "Evidence.count" ] do
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

  test "Framatome fixed but no longer in France isn't taken as already fixed" do
    @framatome.update_columns(hq_city: "Courbevoie", hq_state: nil, country_code: "US")
    assert_raises(RuntimeError) { run_it }
  end

  test "a news item decided since (no longer published) is left to that decision" do
    @news.update_columns(verification_status: "rejected")
    error = assert_raises(RuntimeError) { run_it }
    assert_match "is rejected, not verified", error.message
  end
end
