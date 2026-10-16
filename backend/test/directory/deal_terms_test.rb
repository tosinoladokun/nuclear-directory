require "test_helper"

# Deal terms (#256): one award, offtake or round under its link.
class Directory::DealTermsTest < ActiveSupport::TestCase
  BY = "human:tosin"

  setup do
    @doe = Organization.create!(name: "U.S. Department of Energy", verification_status: "verified", verified_by: BY)
    @xenergy = Organization.create!(name: "X-energy", verification_status: "verified", verified_by: BY)
    @funds = Relationship.create!(from_organization: @doe, to_organization: @xenergy, relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
    @source = sources(:press_release)
  end

  def award(**attributes)
    { link_type: "Relationship", link_id: @funds.id, term_type: "award", external_id: "ASST_NON_DE-NE0009040_8900",
      amount_usd: "80000000.00", starts_on: "2020-10-13", ends_on: "2027-09-30", program: "81.121" }.merge(attributes)
  end

  def write(attributes = award, **options)
    Directory::FactWriter.write(:deal_term, attributes,
      evidence: [ { source_id: @source.id, quote: "ASST_NON_DE-NE0009040_8900 row", found_by: "crawler", confidence: 1 } ], **options)
  end

  test "each kind needs what makes it mean something" do
    term = DealTerm.new(link: @funds, term_type: "award", amount_usd: 1)
    assert_not term.valid?
    assert_includes term.errors.attribute_names, :starts_on
    assert_includes term.errors.attribute_names, :external_id

    assert_not DealTerm.new(link: @funds, term_type: "offtake").valid?
    assert DealTerm.new(link: @funds, term_type: "offtake", capacity_mw: 1121).valid?
    assert_not DealTerm.new(link: @funds, term_type: "funding_round").valid?
    assert DealTerm.new(link: @funds, term_type: "funding_round", round: "Series C-1").valid?
    assert_not DealTerm.new(link: @funds, term_type: "offtake", capacity_mw: 1, starts_on: "2027-06-01", ends_on: "2027-01-01").valid?
    assert_not DealTerm.new(link_type: "Organization", link_id: @xenergy.id, term_type: "offtake", capacity_mw: 1).valid?
  end

  test "the database refuses an award without its amount, date or id, whatever the model says" do
    assert_raises(ActiveRecord::StatementInvalid) do
      DealTerm.insert_all!([ { link_type: "Relationship", link_id: @funds.id, term_type: "award", amount_usd: 1,
        created_at: Time.current, updated_at: Time.current } ])
    end
  end

  test "FactWriter writes a term under its link with its own evidence, and finds it again by its award ID" do
    first = write
    assert first.ok?, first.errors.inspect
    term = DealTerm.find(first.id)
    assert_equal [ @funds, 80_000_000, Date.new(2020, 10, 13) ], [ term.link, term.amount_usd, term.starts_on ]
    assert_equal [ "ASST_NON_DE-NE0009040_8900 row" ], term.evidence.pluck(:quote)

    again = write
    assert_equal first.id, again.id
    assert_equal 1, DealTerm.count
  end

  test "a term needs its link, its link's type and its kind" do
    assert_match "needs both ends", write(award(link_id: nil)).errors.join
    assert_match "link's type", write(award(link_type: "Organization")).errors.join
    assert_match "term type", write(award(term_type: nil)).errors.join
    assert_equal 0, DealTerm.count
  end

  test "no automated term under a rejected or unpublished link" do
    @funds.reject!(by: BY)

    result = write(protect_human_verified: true)

    assert_match "not linked", result.errors.join
    assert_equal 0, DealTerm.count
  end

  test "a changed amount on a human-verified term comes back as a conflict" do
    write(verification: { status: "verified", by: BY })

    result = write(award(amount_usd: "95000000.00"), protect_human_verified: true)

    assert_equal [ "amount_usd" ], result.conflicts.keys.map(&:to_s)
    assert_equal 80_000_000, DealTerm.sole.amount_usd
  end

  test "a term is public only when it's verified and its link is published" do
    write(verification: { status: "verified", by: BY })
    write(award(external_id: "ASST_NON_OTHER"))
    assert_equal [ "ASST_NON_DE-NE0009040_8900" ], Directory::Lookup.deal_terms(link_type: "Relationship", link_id: @funds.id).map(&:external_id)
    assert_equal 2, Directory::Lookup.deal_terms(link_type: "Relationship", link_id: @funds.id, published: false).size

    @funds.unpublish!(by: BY)
    assert_empty Directory::Lookup.deal_terms(link_type: "Relationship", link_id: @funds.id)
  end

  test "the read gives plain values with the term's sources" do
    write(verification: { status: "verified", by: BY })

    ref = Directory::Lookup.deal_terms(link_type: "Relationship", link_id: @funds.id).sole
    assert_equal [ "award", "81.121", [ @source.url ] ], [ ref.term_type, ref.program, ref.source_urls ]
    assert_raises(ArgumentError) { Directory::Lookup.deal_terms(link_type: "Organization", link_id: 1) }
  end

  test "an unknown link type on an update is a refusal, not an exception" do
    id = write.id

    result = Directory::FactWriter.write(:deal_term, { id:, link_type: "Organization" })

    assert_not result.ok?
    assert_equal "Relationship", DealTerm.find(id).link_type
  end

  test "a blank external ID is no ID: two offtakes without one are two rows" do
    offtake = { link_type: "Relationship", link_id: @funds.id, term_type: "offtake", capacity_mw: "1121", external_id: " " }

    assert write(offtake).ok?
    assert write(offtake.merge(capacity_mw: "50")).ok?
    assert_equal [ nil, nil ], DealTerm.where(term_type: "offtake").pluck(:external_id)
  end

  test "a merge moves a retired duplicate link's terms to the kept link, keeping what it already has" do
    duplicate = Organization.create!(name: "X-energy LLC", verification_status: "verified", verified_by: BY)
    other_funds = Relationship.create!(from_organization: @doe, to_organization: duplicate, relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
    write(award(link_id: @funds.id, external_id: "ASST_SHARED"), verification: { status: "verified", by: BY })
    write(award(link_id: other_funds.id, external_id: "ASST_SHARED"), verification: { status: "verified", by: BY })
    write(award(link_id: other_funds.id, external_id: "ASST_ONLY_ON_DUPLICATE"), verification: { status: "verified", by: BY })

    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @xenergy.id, by: BY).ok?

    assert other_funds.reload.rejected?, "the duplicate link is retired"
    assert_equal %w[ASST_ONLY_ON_DUPLICATE ASST_SHARED],
      Directory::Lookup.deal_terms(link_type: "Relationship", link_id: @funds.id).map(&:external_id).sort
    assert_equal [ "ASST_SHARED" ], DealTerm.where(link: other_funds).pluck(:external_id), "a term the kept link has stays behind"
  end
end
