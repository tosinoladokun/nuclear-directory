require "test_helper"
load Rails.root.join("db/data/20261029200000_merge_slash_duplicate_sources.rb")

# DQ's #667: a page stored with and without a trailing slash is one source.
class MergeSlashDuplicateSourcesTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @company = Organization.create!(name: "ConverDyn", verification_status: "verified", verified_by: BY)
    @other = Organization.create!(name: "Honeywell", verification_status: "verified", verified_by: BY)
    @kept = Source.create!(url: "https://www.converdyn.com", source_kind: "web_page")
    @extra = Source.create!(url: "https://www.converdyn.com/", source_kind: "web_page", title: "ConverDyn - Global Provider of UF6")
    @alone = Source.create!(url: "https://example.com/only/", source_kind: "web_page")
    @moving = Evidence.create!(subject: @other, source: @extra, quote: "Honeywell and ConverDyn.", found_by: "human", confidence: 1)
    Evidence.create!(subject: @company, source: @kept, quote: "ConverDyn converts uranium.", found_by: "human", confidence: 1, fields: [ "description" ])
    Evidence.create!(subject: @company, source: @extra, quote: "ConverDyn converts uranium.", found_by: "human", confidence: 1, fields: [ "website" ])
    @claim = Candidate.create!(source: @extra, kind: "organization", payload: { "name" => "ConverDyn" }, quote: "q")
  end

  def run_it = MergeSlashDuplicateSources.new(reason: "deploy abc1234, PR #1").tap(&:up)

  test "merges the slash row into the one without, moving quotes and claims, and a rerun changes nothing" do
    migration = run_it

    assert_not Source.exists?(@extra.id)
    assert Source.exists?(@alone.id), "a slash address with no twin stays"
    assert_equal @kept.id, @moving.reload.source_id
    assert_equal @kept.id, @claim.reload.source_id
    same = Evidence.where(subject: @company, source: @kept)
    assert_equal 1, same.count, "the same quote for the same fact is kept once"
    assert_equal %w[description website], same.sole.fields
    assert_equal "ConverDyn - Global Provider of UF6", @kept.reload.title, "a title the kept row lacked"
    assert_match "1 quotes moved, 1 duplicates dropped, 1 claims moved", migration.output.first

    assert_no_difference -> { Source.count } do
      assert_match "Merged 0 sources", run_it.output.last
    end
  end
end
