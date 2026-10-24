require "test_helper"
require_relative "support/dummy_plugin"

# Deal-term claims through the pipeline (#397), against the real directory:
# a company's own funding round from a Form D, found by the company's SEC
# CIK, proposed pending, approved only by a person.
class DataQuality::DealTermClaimsTest < ActiveSupport::TestCase
  BY = "human:tosin"
  CIK = "0002028336"
  ACCESSION = "0002028336-24-000006"

  # A plug-in whose source holds one Form D's offering fields.
  class FormD < DataQuality::Plugin
    URL = "https://www.sec.gov/Archives/edgar/data/2028336/000202833624000006/xslFormDX01/primary_doc.xml"
    QUOTE = "NEW ERA HELIUM INC. | 0002028336 | 0002028336-24-000006 | D | 2024-12-06 | 105000000 | 37000000"

    def initialize(payload) = @payload = payload
    def source_kind = "dummy_form_d"
    def crawl(_run) = {}
    def extract(_source, _run) = [ { kind: "deal_term", payload: @payload, quote: QUOTE } ]
  end

  def round(**changes)
    { "organization" => { "name" => "NEW ERA HELIUM INC.", "sec_cik" => CIK }, "link_type" => "Organization",
      "term_type" => "funding_round", "external_id" => ACCESSION, "amount_usd" => "37000000.0",
      "amount_offered_usd" => "105000000.0", "starts_on" => "2024-12-06" }.merge(changes.transform_keys(&:to_s)).compact
  end

  def company(name: "New Era Energy & Digital", sec_cik: CIK)
    Directory::FactWriter.write(:organization, { name:, sec_cik: }, verification: { status: "verified", by: BY })
    Organization.find_by!(name:)
  end

  def source
    @source ||= Source.create!(url: FormD::URL, source_kind: "dummy_form_d", crawl_status: "ok", content_text: FormD::QUOTE,
      content_sha256: Digest::SHA256.hexdigest(FormD::QUOTE))
  end

  def claim(payload = round) = Candidate.create!(source:, kind: "deal_term", payload:, quote: FormD::QUOTE)
  def run_stage(stage, payload = round, **) = DataQuality::Pipeline.run("dummy_form_d", plugin: FormD.new(payload), only: stage, **).last

  test "a round is matched to its company by SEC CIK, whatever EDGAR calls it, and proposed pending" do
    issuer = company
    c = claim
    run_stage("match")

    c.reload
    assert_equal [ "matched", "DealTerm", true ], [ c.status, c.subject_type, c.proposed_subject ]
    term = DealTerm.find(c.subject_id)
    assert_equal [ "Organization", issuer.id, "funding_round", ACCESSION ], [ term.link_type, term.link_id, term.term_type, term.external_id ]
    assert_equal [ 37_000_000, 105_000_000, Date.new(2024, 12, 6) ], [ term.amount_usd, term.amount_offered_usd, term.starts_on ]
    assert term.pending?, "nothing is public until a person approves it"
    assert_equal 1, Organization.count { |org| org.sec_cik == CIK }, "EDGAR's spelling made no second company"
  end

  test "a CIK and a name that name different companies: the CIK wins (showing the conflict is #402)" do
    issuer = company
    company(name: "New Era Helium", sec_cik: nil)
    c = claim(round(organization: { "name" => "New Era Helium", "sec_cik" => CIK }))
    run_stage("match")

    assert_equal issuer.id, DealTerm.find(c.reload.subject_id).link_id
  end

  test "a company with no CIK on record is found by name, as before" do
    issuer = company(name: "New Era Helium", sec_cik: nil)
    c = claim(round(organization: { "name" => "New Era Helium", "sec_cik" => CIK }))
    run_stage("match")

    assert_equal issuer.id, DealTerm.find(c.reload.subject_id).link_id
  end

  test "a term under a link must name the link's ends; an unknown link type waits" do
    company
    c = claim(round(link_type: "Relationship"))
    run_stage("match", round(link_type: "Relationship"))
    assert c.reload.status_needs_review?
    assert_match "payload has no from_organization", c.notes

    odd = claim(round(link_type: "Facility"))
    run_stage("match", round(link_type: "Facility"))
    assert_match "link_type must be Organization, Relationship or FacilityRelationship", odd.reload.notes
  end

  test "it reads plainly for the verifier and the queue" do
    text = DataQuality::Claim.describe(Candidate.new(kind: "deal_term", payload: round))

    assert_equal "NEW ERA HELIUM INC. has a funding round, with filing #{ACCESSION}, amount sold $37,000,000, " \
      "amount offered $105,000,000, and first sale on 2024-12-06.", text
  end

  test "a person approves it, and it's public with its company; an amendment lands on the same round" do
    issuer = company
    c = claim
    run_stage("match")
    run_stage("verify", verifier: PublishEverything.new)

    assert_equal DataQuality::Review::BY_A_PERSON, DataQuality::Review.held_reason(c.reload), "never in bulk"
    assert_match "a deal term is decided by a person", DataQuality::Review.approve([ c.id ], by: BY, only_recommended: true).first.errors.first
    assert_empty DataQuality::Review.approve([ c.id ], by: BY).first.errors, "one at a time, a person approves it"

    term = DealTerm.find(c.reload.subject_id)
    assert term.verified?
    assert DealTerm.published.exists?(term.id), "public with its company"
    assert_equal [ source.id ], term.evidence.map(&:source_id)
    assert_equal "#{issuer.name}'s funding round #{ACCESSION}", Directory::Lookup.fact_state(type: "DealTerm", id: term.id).name

    # A Form D/A, on its own filing page: the original's accession, more sold since.
    amendment = Source.create!(url: "https://www.sec.gov/Archives/edgar/data/2028336/000202833625000002/xslFormDX01/primary_doc.xml",
      source_kind: "dummy_form_d", crawl_status: "ok", content_text: FormD::QUOTE, content_sha256: Digest::SHA256.hexdigest(FormD::QUOTE))
    amended = Candidate.create!(source: amendment, kind: "deal_term", payload: round(amount_usd: "52000000.0"), quote: FormD::QUOTE)
    run_stage("match", round(amount_usd: "52000000.0"))
    assert_equal term.id, amended.reload.subject_id, "the same round, by its accession number"
    run_stage("verify", round(amount_usd: "52000000.0"), verifier: PublishEverything.new)
    assert amended.reload.status_needs_review?, "a person decided the round, so a new amount is theirs to accept"
    assert_match "52", amended.notes
    assert_no_match "another page of this source", amended.notes, "an amendment supersedes; there's nothing to combine (#390)"
    assert_empty DataQuality::Review.approve([ amended.id ], by: BY).first.errors, "a person can take the new amount"
    assert_equal 52_000_000, term.reload.amount_usd
  end

  test "a round a person approved, stated again, is confirmed without a review item" do
    company
    first = claim
    run_stage("match")
    DataQuality::Review.approve([ first.id ], by: BY)

    again = claim
    run_stage("match")

    assert again.reload.status_confirmed?
    assert_equal first.reload.subject_id, again.subject_id
  end

  test "no safe class covers deal terms" do
    kinds = DataQuality::SafeClasses::CONFIG.fetch("classes").values.map { |config| config.fetch("kind") }

    assert_not_includes kinds, "deal_term"
  end

  test "the companies with a CIK, for the crawler" do
    company
    company(name: "No CIK Co", sec_cik: nil)

    assert_equal [ [ "New Era Energy & Digital", CIK ] ],
      DataQuality::DirectoryClient.new.organizations_with_sec_cik.map { |ref| [ ref.name, ref.sec_cik ] }
  end

  test "a payload never moves a round: what match resolved wins, and an edit can't change its company" do
    issuer = company
    other = company(name: "Another Co", sec_cik: "0009999999")
    c = claim(round.merge("link_id" => other.id, "id" => 999_999))
    run_stage("match")

    term = DealTerm.find(c.reload.subject_id)
    assert_equal issuer.id, term.link_id, "the company found by its CIK, never the payload's link_id"
    Evidence.create!(subject: term, source:, quote: FormD::QUOTE, found_by: "crawler")

    result = DataQuality::Review.approve_fact(type: "DealTerm", id: term.id, by: BY, attributes: { link_id: other.id })
    assert_not result.ok?
    assert_equal issuer.id, term.reload.link_id
  end

  test "a deal between two companies (#256) attaches to their link, proposed pending with its terms; no link yet waits; the same deal again is the same row" do
    buyer = Directory::FactWriter.write(:organization, { name: "Big Data Co" }, verification: { status: "verified", by: BY }) && Organization.find_by!(name: "Big Data Co")
    seller = company(name: "Small Reactor Co", sec_cik: nil)
    deal = { "link_type" => "Relationship", "from_organization" => { "name" => "Small Reactor Co" }, "to_organization" => { "name" => "Big Data Co" },
      "relationship_type" => "offtake_with", "term_type" => "offtake", "external_id" => "release-2026-10-01", "capacity_mw" => "500",
      "agreement" => "ppa", "status" => "signed", "signed_on" => "2026-10-01" }

    waiting = claim(deal)
    run_stage("match", deal)
    assert waiting.reload.status_needs_review?
    assert_match "isn't in the directory yet: approve the link first", waiting.notes

    Directory::FactWriter.write(:relationship, { from_organization_id: seller.id, to_organization_id: buyer.id, relationship_type: "offtake_with" },
      verification: { status: "verified", by: BY })
    link = Relationship.find_by!(from_organization_id: seller.id, to_organization_id: buyer.id)
    first = claim(deal)
    run_stage("match", deal)
    term = DealTerm.find(first.reload.subject_id)
    assert_equal [ "Relationship", link.id, "offtake", "ppa", "signed", 500 ], [ term.link_type, term.link_id, term.term_type, term.agreement, term.status, term.capacity_mw.to_i ]
    assert term.pending?

    again = claim(deal)
    run_stage("match", deal)
    assert_equal term.id, again.reload.subject_id
    assert_equal 1, DealTerm.count
  end

  test "a deal on a link a person rejected isn't added" do
    a = company(name: "Rejected A", sec_cik: nil)
    b = company(name: "Rejected B", sec_cik: "0000000001")
    Directory::FactWriter.write(:relationship, { from_organization_id: a.id, to_organization_id: b.id, relationship_type: "supplies" },
      verification: { status: "rejected", by: BY })
    deal = { "link_type" => "Relationship", "from_organization" => { "name" => "Rejected A" }, "to_organization" => { "name" => "Rejected B" },
      "relationship_type" => "supplies", "term_type" => "offtake", "amount_usd" => "1000000" }
    c = claim(deal)
    run_stage("match", deal)
    assert_match "so no term is added to it", c.reload.notes
    assert_equal 0, DealTerm.count
  end

  test "a deal reads with both parties" do
    deal = { "link_type" => "Relationship", "from_organization" => { "name" => "Small Reactor Co" }, "to_organization" => { "name" => "Big Data Co" },
      "relationship_type" => "offtake_with", "term_type" => "offtake", "capacity_mw" => "500" }
    text = DataQuality::Claim.describe(claim(deal))
    assert_match(/\ASmall Reactor Co has an offtake agreement with Big Data Co: an offtake, with .*500/, text)
  end
end
