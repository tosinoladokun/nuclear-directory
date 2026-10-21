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
    assert_match "link's type", write(award(link_type: "Facility")).errors.join
    assert_match "term type", write(award(term_type: nil)).errors.join
    assert_equal 0, DealTerm.count
  end

  test "no automated term under a rejected or unpublished link" do
    @funds.reject!(by: BY)

    result = write(protect_human_verified: true)

    assert_match "not linked", result.errors.join
    assert_equal 0, DealTerm.count
  end

  # #377: fact_state only knows FACT_TYPES, so a closed-fact error on a
  # DealTerm (not in FACT_TYPES yet) used to raise "not a fact type".
  # record_label labels the term from its own fields instead.
  test "a write to a rejected deal term says what was rejected, not 'not a fact type' (#377)" do
    first = write(verification: { status: "verified", by: BY })
    term = DealTerm.find(first.id)
    term.reject!(by: BY, reason: "duplicate")

    result = write(award(amount_usd: "95000000.00"), protect_human_verified: true)

    assert_match(/\AAward ASST_NON_DE-NE0009040_8900 \(##{term.id}\) was rejected by #{Regexp.escape(BY)}/, result.errors.join)
    assert_equal 80_000_000, DealTerm.sole.amount_usd, "nothing written"
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
    assert_raises(ArgumentError) { Directory::Lookup.deal_terms(link_type: "Facility", link_id: 1) }
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

  test "a merge names the kept company as lead investor on any round, once each, in order" do
    investor = Organization.create!(name: "Lowercarbon", verification_status: "verified", verified_by: BY)
    duplicate = Organization.create!(name: "Lowercarbon Capital", verification_status: "verified", verified_by: BY)
    other = Organization.create!(name: "Founders Fund", verification_status: "verified", verified_by: BY)
    # A round under a link neither company is on: X-energy raising from DOE's link stands in for any.
    both = DealTerm.create!(link: @funds, term_type: "funding_round", round: "Series D", lead_investor_ids: [ duplicate.id, other.id, investor.id ])
    alone = DealTerm.create!(link: @funds, term_type: "funding_round", round: "Series C", lead_investor_ids: [ other.id, duplicate.id ])
    closed = DealTerm.create!(link: @funds, term_type: "funding_round", round: "Series B", lead_investor_ids: [ duplicate.id ])
    closed.reject!(by: BY, reason: "Wrong round")

    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: investor.id, by: BY).ok?

    assert_equal [ investor.id, other.id ], both.reload.lead_investor_ids, "named once, where it first was"
    assert_equal [ other.id, investor.id ], alone.reload.lead_investor_ids
    assert_equal [ duplicate.id ], closed.reload.lead_investor_ids, "a rejected term stays as decided"
    assert_match "2 lead investors", duplicate.verification_events.order(:id).last.reason
  end

  test "a merge locks a retiring link before reading its terms, so a term written meanwhile can't stay behind" do
    duplicate = Organization.create!(name: "X-energy LLC", verification_status: "verified", verified_by: BY)
    retired = Relationship.create!(from_organization: @doe, to_organization: duplicate, relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
    DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_LOCK", amount_usd: 5, starts_on: "2024-01-01")
    sql = []
    record = ->(*, payload) { sql << payload[:sql] }

    ActiveSupport::Notifications.subscribed(record, "sql.active_record") do
      assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @xenergy.id, by: BY).ok?
    end

    lock = sql.index { |q| q.match?(/FROM "relationships" WHERE "relationships"."id" = \$1.*FOR UPDATE/m) && q.include?("relationships") }
    read = sql.index { |q| q.match?(/FROM "deal_terms" WHERE "deal_terms"."link_type"/) }
    assert lock && read && lock < read, "the retiring link is locked before its terms are read"
    assert_equal @funds, DealTerm.find_by!(external_id: "ASST_LOCK").link
  end

  test "a link a person closed after the merge read it keeps its terms" do
    retired = Relationship.create!(from_organization: @doe, to_organization: Organization.create!(name: "X-energy LLC"),
      relationship_type: "funds", verification_status: "verified", verified_by: BY)
    term = DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_CLOSED_LATE", amount_usd: 5, starts_on: "2024-01-01")
    as_read = Relationship.find(retired.id) # what the merge saw: still open
    retired.reject!(by: BY, reason: "Not a DOE award") # a person, before the merge's lock

    assert_equal 0, Directory::FactWriter.new.send(:move_deal_terms, as_read, @funds)
    assert_equal retired, term.reload.link
  end

  test "a term a person decided after the merge picked it stays as they decided" do
    retired = Relationship.create!(from_organization: @doe, to_organization: Organization.create!(name: "X-energy LLC"),
      relationship_type: "funds", verification_status: "verified", verified_by: BY)
    rejected = DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_REJECTED_LATE", amount_usd: 5, starts_on: "2024-01-01")
    moved_away = DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_MOVED_LATE", amount_usd: 5, starts_on: "2024-01-01")
    other = Relationship.create!(from_organization: @doe, to_organization: Organization.create!(name: "Kairos Power"), relationship_type: "funds")
    writer = Directory::FactWriter.new
    picked = [ DealTerm.find(rejected.id), DealTerm.find(moved_away.id) ] # as the merge selected them
    writer.define_singleton_method(:deal_terms_moving) { |*| picked }
    rejected.reject!(by: BY, reason: "Wrong award") # a person, before the merge moves it
    moved_away.update!(link: other)

    assert_equal 0, writer.send(:move_deal_terms, retired, @funds)
    assert_equal [ retired, true ], [ rejected.reload.link, rejected.rejected? ]
    assert_equal other, moved_away.reload.link
  end

  test "a merge stops, to be tried again, when another merge retired the kept link meanwhile" do
    retired = Relationship.create!(from_organization: @doe, to_organization: Organization.create!(name: "X-energy LLC"),
      relationship_type: "funds", verification_status: "verified", verified_by: BY)
    term = DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_KEPT_CLOSED", amount_usd: 5, starts_on: "2024-01-01")
    kept = Relationship.find(@funds.id) # as this merge found it: open
    @funds.reject!(by: BY, reason: "Merged into DOE (#1); already has this") # the other merge, first

    error = assert_raises(Directory::FactWriter::Invalid) { Directory::FactWriter.new.send(:move_deal_terms, retired, kept) }
    assert_match "try the merge again", error.message
    assert_equal retired, term.reload.link, "nothing moved onto the closed link"
  end

  test "a kept link a person already closed doesn't block a company merge; the terms stay put" do
    duplicate = Organization.create!(name: "X-energy LLC", verification_status: "verified", verified_by: BY)
    retired = Relationship.create!(from_organization: @doe, to_organization: duplicate, relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
    term = DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_STAYS", amount_usd: 5, starts_on: "2024-01-01")
    @funds.reject!(by: BY, reason: "Not a DOE award")

    _, preview = Directory::FactWriter.merge_preview(type: "Organization", from_id: duplicate.id, into_id: @xenergy.id)
    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @xenergy.id, by: BY).ok?
    assert_equal retired, term.reload.link
    assert @funds.reload.rejected?, "the person's decision stands"
    assert_no_match(/deal term/, preview)
  end

  test "a kept plant link a person already closed doesn't block a plant merge; the terms stay put" do
    site = Facility.create!(name: "Plant Vogtle", verification_status: "verified", verified_by: BY)
    duplicate = Facility.create!(name: "Vogtle", verification_status: "verified", verified_by: BY)
    kept = FacilityRelationship.create!(organization: @xenergy, facility: site, relationship_type: "offtakes_from",
      verification_status: "verified", verified_by: BY)
    retired = FacilityRelationship.create!(organization: @xenergy, facility: duplicate, relationship_type: "offtakes_from",
      verification_status: "verified", verified_by: BY)
    term = DealTerm.create!(link: retired, term_type: "offtake", capacity_mw: 100)
    kept.reject!(by: BY, reason: "Not an offtake")

    _, preview = Directory::FactWriter.merge_preview(type: "Facility", from_id: duplicate.id, into_id: site.id)
    assert Directory::FactWriter.merge_facility(from_id: duplicate.id, into_id: site.id, by: BY).ok?
    assert_equal retired, term.reload.link
    assert_no_match(/deal term/, preview)
  end

  test "the merge preview counts the terms and lead investors the merge moves" do
    duplicate = Organization.create!(name: "X-energy LLC", verification_status: "verified", verified_by: BY)
    retired = Relationship.create!(from_organization: @doe, to_organization: duplicate, relationship_type: "funds",
      verification_status: "verified", verified_by: BY)
    DealTerm.create!(link: retired, term_type: "award", external_id: "ASST_MOVES", amount_usd: 5, starts_on: "2024-01-01")
    DealTerm.create!(link: @funds, term_type: "funding_round", round: "Seed", lead_investor_ids: [ duplicate.id ])

    _, preview = Directory::FactWriter.merge_preview(type: "Organization", from_id: duplicate.id, into_id: @xenergy.id)
    assert Directory::FactWriter.merge_organization(from_id: duplicate.id, into_id: @xenergy.id, by: BY).ok?

    moved = duplicate.verification_events.order(:id).last.reason[/Moved: (.*)\z/, 1]
    assert_equal moved, preview
    assert_match "1 deal term", preview
    assert_match "1 lead investor", preview
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
