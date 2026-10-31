require "test_helper"
load Rails.root.join("db/data/20261029210000_bare_homepage_source_urls.rb")

# #670: a bare homepage's Source takes its address without the trailing slash.
class BareHomepageSourceUrlsTest < ActiveSupport::TestCase
  def run_it = BareHomepageSourceUrls.new(reason: "deploy abc1234, PR #1").tap(&:up)

  # Written in SQL, past the model's normalisation, as rows saved before #670 were.
  def stored(url)
    Source.connection.select_value("INSERT INTO sources (url, source_kind, crawl_status, created_at, updated_at) " \
      "VALUES (#{Source.connection.quote(url)}, 'web_page', 'pending', NOW(), NOW()) RETURNING id")
  end

  test "renames a slash-only homepage, leaves paths and a row whose twin exists, and a rerun changes nothing" do
    homepage = stored("https://www.mit.edu/")
    path = stored("https://www.orano.group/usa/en/")
    twin_slash = stored("https://example.com/")
    stored("https://example.com")

    migration = run_it

    assert_equal "https://www.mit.edu", Source.find(homepage).url
    assert_equal "https://www.orano.group/usa/en/", Source.find(path).url, "a path beyond the host isn't touched"
    assert_equal "https://example.com/", Source.find(twin_slash).url, "a pair is left for a person"
    assert_match "https://example.com/: left as it is", migration.output.first
    assert_includes migration.output, "Gave 1 homepage sources their address without the trailing slash"
    assert_includes run_it.output, "Gave 0 homepage sources their address without the trailing slash"
  end

  test "re-keys a page's deal terms and open claims to the address without the slash, unless the new key is taken" do
    company = Organization.create!(name: "Acme", verification_status: "verified", verified_by: "human:tosin")
    term = DealTerm.create!(link: company, term_type: "funding_round", round: "Series B", amount_usd: 1,
      external_id: "page:https://www.acme.com/#series b 1.0", verification_status: "verified", verified_by: "human:tosin")
    claim = Candidate.create!(source: Source.create!(url: "https://www.acme.com", source_kind: "web_page"), kind: "organization", quote: "q",
      payload: { "external_id" => "page:https://www.acme.com/#seed 2.0" })

    migration = run_it

    assert_equal "page:https://www.acme.com#series b 1.0", term.reload.external_id
    assert_equal "page:https://www.acme.com#seed 2.0", claim.reload.payload["external_id"]
    assert_match "Re-keyed 1 deal terms and 1 claims", migration.output.last
  end

  test "an upper-case scheme counts too; a fragment page's key stays; a rejected claim is re-keyed; a skipped term keeps its claims' keys" do
    upper = stored("HTTPS://Example.org/")
    company = Organization.create!(name: "Acme", verification_status: "verified", verified_by: "human:tosin")
    page = Source.create!(url: "https://www.acme.com", source_kind: "web_page")
    fragment = DealTerm.create!(link: company, term_type: "funding_round", round: "A", amount_usd: 1,
      external_id: "page:https://www.acme.com/#investors#series a 1.0", verification_status: "verified", verified_by: "human:tosin")
    rejected = Candidate.create!(source: page, kind: "deal_term", quote: "q", status: "rejected",
      payload: { "external_id" => "page:https://www.acme.com/#seed 2.0" })
    taken = DealTerm.create!(link: company, term_type: "funding_round", round: "B", amount_usd: 3,
      external_id: "page:https://www.acme.com#series b 3.0", verification_status: "verified", verified_by: "human:tosin")
    stuck = DealTerm.create!(link: company, term_type: "funding_round", round: "B", amount_usd: 3,
      external_id: "page:https://www.acme.com/#series b 3.0", verification_status: "verified", verified_by: "human:tosin")
    on_stuck = Candidate.create!(source: page, kind: "deal_term", quote: "q", status: "matched", subject: stuck,
      payload: { "external_id" => "page:https://www.acme.com/#series b 3.0" })

    migration = run_it

    assert_equal "HTTPS://Example.org", Source.find(upper).url
    assert_equal "page:https://www.acme.com/#investors#series a 1.0", fragment.reload.external_id, "a fragment page keeps its key"
    assert_equal "page:https://www.acme.com#seed 2.0", rejected.reload.payload["external_id"]
    assert rejected.status_rejected?, "its decision doesn't change"
    assert_equal "page:https://www.acme.com/#series b 3.0", stuck.reload.external_id
    assert_equal "page:https://www.acme.com/#series b 3.0", on_stuck.reload.payload["external_id"], "its claims keep the key with it"
    assert_equal "page:https://www.acme.com#series b 3.0", taken.reload.external_id
    assert(migration.output.any? { |line| line.include?("Claim #{on_stuck.id}: key left as it is") })
  end
end
