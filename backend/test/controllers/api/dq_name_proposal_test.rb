require "test_helper"
require_relative "../../data_quality/support/dummy_plugin"

# #1000: Data Quality proposes the display name for a pending company, with a
# quote. Create uses it; the crawler's spelling stays an alias; a published
# company's name can't be changed this way.
class Api::DqNameProposalTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  TOKEN = "dq-test-token".freeze
  QUOTE = "Fermi America is building the HyperGrid campus in Amarillo.".freeze

  setup do
    ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN)
    @page = Source.create!(url: "https://www.nrc.gov/test/fermi.html", source_kind: "dummy", crawl_status: "ok", content_sha256: "sha",
      content_text: "Licensee: Fermi Nuclear. #{QUOTE}")
    @company = give_sourced_role(Organization.create!(name: "Fermi Nuclear", verification_status: "pending"))
    @create = Candidate.create!(source: @page, kind: "organization", status: "needs_review", quote: "Licensee: Fermi Nuclear.",
      payload: { "name" => "Fermi Nuclear" }, subject: @company, proposed_subject: true)
  end

  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    Api::Dq::MatchingController::RATE_LIMIT_STORE.clear
  end

  def act(*rows) = post(api_dq_matching_path, params: { actions: rows }, as: :json, headers: { "Authorization" => "Bearer #{TOKEN}" })
  def results = response.parsed_body["results"]
  def propose(name, target: @company.id, quote: QUOTE, **fields)
    act({ action: "propose_fields", target:, fields: { name:, **fields }, quote:, source_url: @page.url, reason: "Its own site" })
    results.first
  end

  def proposed(name = "Fermi America", quote: QUOTE)
    row = propose(name, quote:)
    assert row["ok"], row.inspect
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)
    Candidate.find(row["id"])
  end

  test "a pending company's name, with a quote that uses it, becomes a claim on that company carrying the crawler's spelling as an alias" do
    claim = proposed

    assert_equal({ "name" => "Fermi America", "replaces" => "Fermi Nuclear" }, claim.payload)
    assert_not_includes DataQuality::Claim.describe(claim), "Fermi Nuclear", "the verifier never asks the page for the crawler's spelling (Copilot)"
    assert_equal [ "matched", "Organization", @company.id ], claim.values_at(:status, :subject_type, :subject_id), claim.notes
    assert_equal 1, Organization.where("name ILIKE 'Fermi%'").count, "found by the company Data Quality named, never proposed as a second one"
    assert_equal "new_record", DataQuality::Review.inbox_kind(claim), "part of its Create"
    assert_equal "Fermi Nuclear", @company.reload.name, "nothing changes before Create"
  end

  test "Create uses the proposed name; the crawler's spelling stays an alias and its address moves to the new name" do
    claim = proposed
    results = DataQuality::Review.approve([ @create.id, claim.id ], by: "human:tosin", reason: "Created in Today")

    assert results.all?(&:ok?), results.flat_map(&:errors).inspect
    @company.reload
    assert_equal [ "Fermi America", "verified", "fermi-america" ], @company.values_at(:name, :verification_status, :slug)
    assert_includes @company.aliases.pluck(:alias), "Fermi Nuclear"
    assert_equal @company.id, Directory::Lookup.organization(name: "Fermi Nuclear")&.id, "later matches still find it by the old spelling"
    assert_equal @company, Organization.find_by_former_slug("fermi-nuclear")
  end

  test "approved first, the name claim names the pending company, and Create keeps it" do
    claim = proposed
    DataQuality::Review.approve([ claim.id ], by: "human:tosin", reason: "Approved in Today")
    DataQuality::Review.approve([ @create.id ], by: "human:tosin", reason: "Created in Today")

    assert_equal [ "Fermi America", "verified" ], @company.reload.values_at(:name, :verification_status)
  end

  test "Tosin's Create row shows the proposed name, the spelling it was found as, and the quote" do
    claim = proposed
    DataQuality::Recommendations.record("#{@create.id} approve: named on the NRC page\n#{claim.id} approve: its own site", by: "human:dq")
    sign_in_as users(:admin)

    get admin_inbox_path

    assert_select "#inbox-item-#{@create.id}" do
      assert_select "strong", "Fermi America"
      assert_select "#proposed-name-#{claim.id}", "Found as Fermi Nuclear, which stays as another name for it."
      assert_select "#also-claim-#{claim.id}", /Name: Fermi America/
      assert_select "#also-claim-#{claim.id} blockquote", /#{QUOTE}/
    end
    assert_select "#inbox-item-#{claim.id}", 0, "on the Create's row, not its own"
  end

  test "a page that names only the new name supports the claim: the verifier reads just the proposed name (Copilot)" do
    @page.update!(content_text: QUOTE)
    claim = proposed
    seen = []
    verifier = Struct.new(:seen) { def call(candidate) = seen << DataQuality::Claim.describe(candidate) && DataQuality::Verdict.new(outcome: :review, reason: "asked") }.new(seen)
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: "verify", verifier:)

    assert_equal [ "There is a company named “Fermi America”." ], seen
    assert_equal "asked", claim.reload.notes, "checked by the verifier, not held for a missing quote"
  end

  test "Create approved first: the name proposal left is a change on Tosin's list, Fermi Nuclear → Fermi America, never hidden (Copilot)" do
    claim = proposed
    DataQuality::Review.approve([ @create.id ], by: "human:tosin", reason: "Created in Today")

    assert_equal "change", DataQuality::Review.inbox_kind(claim.reload)
    changes = DataQuality::Differences.changes(claim, DataQuality::DirectoryClient.new.fact(type: "Organization", id: @company.id), directory: DataQuality::DirectoryClient.new)
    assert_equal({ "name" => [ "Fermi Nuclear", "Fermi America" ] }, changes)
    assert_not DataQuality::Review.evidence_only?(claim, directory: DataQuality::DirectoryClient.new), "never a bulk Yes"
  end

  test "a CIK the proposal carries that's another company's by match goes to review, as on the usual path (Copilot)" do
    act({ action: "propose_fields", target: @company.id, fields: { name: "Fermi America", sec_cik: "0001234567" }, quote: QUOTE,
          source_url: "https://www.sec.gov/cgi-bin/browse-edgar?CIK=0001234567", reason: "EDGAR" })
    row = results.first
    assert row["ok"], row.inspect
    Organization.create!(name: "Other Co", verification_status: "verified", verified_by: "human:tosin", sec_cik: "0001234567")
    DataQuality::Stages::Match.call(plugin: DataQuality::Plugins::WebPage.new)

    claim = Candidate.find(row["id"])
    assert_equal "needs_review", claim.status
    assert_match "SEC CIK 0001234567 is Other Co's", claim.notes
  end

  test "two name proposals: the Create row shows the last, the one approval applies (Copilot)" do
    first = proposed
    @page.update!(content_text: "#{@page.content_text} Fermi America Inc. is its legal name.")
    second = proposed("Fermi America Inc.", quote: "Fermi America Inc. is its legal name.")
    entry = OwnerInbox::Entry.new(kind: "new_record", item: nil, copy_ids: [ first.id, second.id ], checked: false, changes: {})

    assert_equal second, ApplicationController.helpers.proposed_name_claim(entry)
    DataQuality::Review.approve([ @create.id, first.id, second.id ], by: "human:tosin", reason: "Created in Today")
    assert_equal "Fermi America Inc.", @company.reload.name
  end

  test "a published company's name can't be proposed: renaming it stays a reviewed change" do
    @company.verify!(by: "human:tosin")

    row = propose("Fermi America")

    assert_not row["ok"]
    assert_equal "Fermi Nuclear is published; its name can't be proposed this way", row["error"]
    assert_not Candidate.where(kind: "organization").where("payload->>'name' = ?", "Fermi America").exists?
  end

  test "published between the proposal and match: the claim goes to review, and the name isn't changed" do
    row = propose("Fermi America")
    @company.verify!(by: "human:tosin")
    DataQuality::Stages::Match.call(plugin: DummyPlugin.new)

    claim = Candidate.find(row["id"])
    assert_equal "needs_review", claim.status
    assert_match "is published now; a published company's name changes by a reviewed change", claim.notes
    assert_equal "Fermi Nuclear", @company.reload.name
  end

  test "the quote must use the name; the name must be new, and not another company's" do
    Organization.create!(name: "AEP", verification_status: "verified", verified_by: "human:tosin").aliases.create!(alias: "AEP")

    assert_equal "the quote must contain the name Fermi Energy", propose("Fermi Energy")["error"]
    assert_equal '"Fermi Nuclear" is already its name', propose("Fermi Nuclear", quote: "Licensee: Fermi Nuclear.")["error"]
    assert_match(/"AEP" is AEP's \(#\d+\); if they're the same company, settle it with same_as/, propose("AEP", quote: "AEP owns it.")["error"])
    assert_match "a name is 120 characters at most", propose("A" * 121, quote: "A" * 121)["error"]
  end

  test "the verifier checks the quote as usual: one that isn't on the page goes to review" do
    row = propose("Fermi America", quote: "Fermi America builds reactors.")
    DataQuality::Pipeline.run("dummy", plugin: DummyPlugin.new, only: %w[match verify], verifier: ->(_) { raise "not asked" }.then { |never| Struct.new(:call).new(never) })

    claim = Candidate.find(row["id"])
    assert_equal [ "needs_review", "quote_missing" ], [ claim.status, claim.ai_reason.to_s[/isn't in the source/] && "quote_missing" ]
  end
end
