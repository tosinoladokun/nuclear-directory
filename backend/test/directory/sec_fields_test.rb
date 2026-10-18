require "test_helper"

# SEC EDGAR's fields (#129): a company's SEC CIK, and a Form D round on the
# company itself (PM, 18 Oct 2026).
class Directory::SecFieldsTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @source = sources(:press_release)
    @company = Organization.create!(name: "Kairos Power", verification_status: "verified", verified_by: BY)
  end

  def form_d(**attributes)
    { link_type: "Organization", link_id: @company.id, term_type: "funding_round", external_id: "0001234567-24-000001",
      amount_usd: "50000000.00", amount_offered_usd: "75000000.00", starts_on: "2024-03-01" }.merge(attributes)
  end

  def write(attributes = form_d, **options)
    Directory::FactWriter.write(:deal_term, attributes,
      evidence: [ { source_id: @source.id, quote: "Form D row", found_by: "crawler", confidence: 1 } ], **options)
  end

  test "a CIK is stored as EDGAR writes it, 10 digits, and is unique" do
    assert_equal "0001234567", Organization.create!(name: "A", sec_cik: "CIK1234567").sec_cik
    assert_equal "0000320193", Organization.new(sec_cik: " 320193 ").sec_cik
    assert_nil Organization.new(sec_cik: "").sec_cik
    assert_not Organization.new(name: "B", sec_cik: "12-345").valid?
    assert_not Organization.new(name: "C", sec_cik: "1234567").valid?, "taken"
    assert_raises(ActiveRecord::StatementInvalid) { Organization.new(name: "D").tap { |o| o.save!(validate: false) }.update_columns(sec_cik: "123") }
  end

  test "FactWriter finds a company by its CIK before its name" do
    @company.update!(sec_cik: "0001820953")
    result = Directory::FactWriter.write(:organization, { name: "KAIROS POWER LLC", sec_cik: "1820953" },
      evidence: [ { source_id: @source.id, quote: "KAIROS POWER LLC", found_by: "crawler" } ], protect_human_verified: true)

    assert_equal @company.id, result.id, "EDGAR's spelling differs; the CIK finds it"
    assert_equal @company.id, Directory::Lookup.organization(sec_cik: "CIK0001820953").id
  end

  test "a Form D round sits on the company, with the amount offered, and is found again by its accession number" do
    first = write
    assert first.ok?, first.errors.to_sentence
    again = write(form_d(amount_usd: "55000000.00"), protect_human_verified: true) # a Form D/A, same original accession

    term = DealTerm.find(first.id)
    assert_equal first.id, again.id
    assert_equal [ @company, 75_000_000 ], [ term.link, term.amount_offered_usd ]
    assert_equal BigDecimal("55000000"), term.reload.amount_usd, "the amendment updates the same round"
  end

  test "only a funding round can sit on a company, in the model and the database" do
    assert_not DealTerm.new(link: @company, term_type: "award", amount_usd: 1, starts_on: "2024-01-01", external_id: "X").valid?
    assert_raises(ActiveRecord::StatementInvalid) do
      DealTerm.new(link: @company, term_type: "offtake", capacity_mw: 1).tap { |t| t.save!(validate: false) }
    end
  end

  test "a company's round is public with the company, and not through a closed one" do
    term = DealTerm.find(write.id)
    term.verify!(by: BY)
    assert_includes DealTerm.published, term
    assert_equal [ term.id ], Directory::Lookup.deal_terms(link_type: "Organization", link_id: @company.id).map(&:id)

    @company.unpublish!(by: BY, reason: "Test")
    assert_not_includes DealTerm.published, term
  end

  test "a merge moves the duplicate's CIK and its own rounds, and the preview says so" do
    duplicate = Organization.create!(name: "Kairos Power LLC", sec_cik: "1820953", verification_status: "verified", verified_by: BY)
    DealTerm.create!(link: duplicate, term_type: "funding_round", round: "Series A", external_id: "0001820953-21-000001")

    _, preview = Directory::FactWriter.merge_preview(type: "Organization", from_id: duplicate.id, into_id: @company.id)
    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @company.id, by: BY).ok?

    assert_equal "0001820953", @company.reload.sec_cik
    assert_equal @company, DealTerm.find_by!(external_id: "0001820953-21-000001").link
    assert_equal duplicate.verification_events.order(:id).last.reason[/Moved: (.*)\z/, 1], preview
    assert_match "1 SEC CIK", preview
    assert_match "1 deal term", preview
  end
end
