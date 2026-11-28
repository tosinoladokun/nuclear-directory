require "test_helper"
require_relative "../support/fake_directory"
require_relative "../support/dummy_plugin"

# Only a plug-in that holds claims back (EIA owners, #996) has extract load
# the source's earlier claims (#1038).
class DataQuality::Stages::ExtractEarlierClaimsTest < ActiveSupport::TestCase
  # Holds back nothing: never asked which claim waits.
  class Plain < DummyPlugin
    def waiting_claim(*) = raise("asked which claim waits")
  end

  # Holds back NewCo Fission while its first claim waits.
  class Holding < DummyPlugin
    def earlier_claims(source) = source.candidates.where(kind: "organization", status: %w[needs_review rejected])
    def waiting_claim(attrs, earlier) = earlier.find { |claim| claim.payload["name"] == attrs[:payload]["name"] }
  end

  def read!(plugin)
    Source.find_by(url: DummyPlugin::URL)&.update_columns(extracted_sha256: nil, extracted_rows_sha256: nil)
    DataQuality::Pipeline.run("dummy", plugin:, directory: FakeDirectory.client, only: %w[crawl extract])
  end

  def queries_for_earlier_claims
    seen = []
    counter = lambda do |*, payload|
      values = Array(payload[:type_casted_binds]).map { |value| value.is_a?(Array) ? value : [ value ] }.flatten
      seen << payload[:sql] if payload[:sql].include?("candidates") && (values.include?("rejected") || payload[:sql].include?("'rejected'"))
    end
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    seen
  end

  test "a plug-in that holds nothing back runs no query for earlier claims" do
    assert_nil DataQuality::Plugin.new.earlier_claims(Source.new)
    read!(Plain.new)
    Candidate.where(kind: "organization").update_all(status: "needs_review", review_origin: "match")

    assert_empty queries_for_earlier_claims { read!(Plain.new) }
    assert_equal 4, Candidate.where(kind: "organization").count, "each read proposes both again, as before #996"
  end

  test "a plug-in that holds claims back still gets them" do
    read!(Holding.new)
    Candidate.where(kind: "organization").update_all(status: "needs_review", review_origin: "match")

    assert_not_empty queries_for_earlier_claims { read!(Holding.new) }, "the counter sees the query when it runs"
    assert_equal 2, Candidate.where(kind: "organization").count, "both still waiting: neither proposed again"
  end
end
