require "test_helper"

# #556: a deal row's short "what", one case per row of the spec's table.
class DealLineTest < ActiveSupport::TestCase
  Term = Struct.new(:id, :term_type, :amount_usd, :program, :round, :lead_investor_ids, :capacity_mw, :agreement, :ends_on, :term_years,
    :signed_on, :starts_on, keyword_init: true)
  Company = Struct.new(:id)

  def term(**values) = Term.new(id: 1, lead_investor_ids: [], **values)

  test "an award: amount, program, award" do
    assert_equal "$80M ARDP award", DealLine.for(term(term_type: "award", amount_usd: 80_000_000, program: "ARDP"))
    assert_equal "$1.23B award", DealLine.for(term(term_type: "award", amount_usd: 1_234_000_000))
    assert_nil DealLine.for(term(term_type: "award")), "nothing stored: nothing said"
  end

  test "a funding round: amount and round, Anchors when this company led it" do
    round = term(term_type: "funding_round", amount_usd: 500_000_000, round: "Series C-1", lead_investor_ids: [ 7 ])
    assert_equal "Anchors $500M Series C-1", DealLine.for(round, company: Company.new(7))
    assert_equal "$500M Series C-1", DealLine.for(round, company: Company.new(8))
    assert_equal "$750K round", DealLine.for(term(term_type: "funding_round", amount_usd: 750_000))
  end

  test "an offtake: capacity (GW from 1,000 MW), agreement, end year when known" do
    assert_equal "5 GW framework by 2039", DealLine.for(term(term_type: "offtake", capacity_mw: 5000, agreement: "framework", ends_on: Date.new(2039, 12, 31)))
    assert_equal "500 MW PPA for 20 years", DealLine.for(term(term_type: "offtake", capacity_mw: 500, agreement: "ppa", term_years: 20))
    assert_equal "1.5 GW", DealLine.for(term(term_type: "offtake", capacity_mw: 1500))
  end

  test "no term: nothing, so the row shows name and verb only" do
    assert_nil DealLine.for_terms([])
  end

  test "never over 40 characters: drops the last detail, never the amount" do
    long = term(term_type: "funding_round", amount_usd: 1_200_000_000, round: "Series C-1 Extension Preferred Units", lead_investor_ids: [ 7 ])
    assert_equal "Anchors $1.2B", DealLine.for(long, company: Company.new(7))
    fits = term(term_type: "offtake", capacity_mw: 1234.5, agreement: "development_agreement", ends_on: Date.new(2040, 1, 1))
    assert_equal "1.2 GW development agreement by 2040", DealLine.for(fits)
  end

  test "a link's newest term that makes a line" do
    older = term(term_type: "award", amount_usd: 10_000_000, program: "GAIN", signed_on: Date.new(2023, 1, 1))
    newer = Term.new(id: 2, term_type: "award", lead_investor_ids: [], signed_on: Date.new(2025, 1, 1))
    assert_equal "$10M GAIN award", DealLine.for_terms([ older, newer ]), "the newer has nothing stored"
  end

  test "shortened to a bare prefix: nothing, so an older term can give the line" do
    long = term(term_type: "funding_round", round: "Series C-1 Extension Preferred Units Tranche", lead_investor_ids: [ 7 ], signed_on: Date.new(2025, 1, 1))
    assert_nil DealLine.for(long, company: Company.new(7))
    older = Term.new(id: 2, term_type: "award", lead_investor_ids: [], amount_usd: 5_000_000, program: "GAIN", signed_on: Date.new(2023, 1, 1))
    assert_equal "$5M GAIN award", DealLine.for_terms([ long, older ], company: Company.new(7))
  end

  test "a loan: amount, lender's short name, loan" do
    doe = Struct.new(:name, :short_name).new("U.S. Department of Energy", "DOE")
    link = Struct.new(:from_organization).new(doe)
    loan = Struct.new(*Term.members, :link, keyword_init: true).new(id: 1, term_type: "loan", amount_usd: 1_520_000_000, lead_investor_ids: [], link:)
    assert_equal "$1.52B DOE loan", DealLine.for(loan)
    assert_equal "$1B loan", DealLine.for(term(term_type: "loan", amount_usd: 1_000_000_000))
    bank = Struct.new(:name, :short_name).new("International Development Bank", nil)
    long = Struct.new(*Term.members, :link, keyword_init: true).new(id: 2, term_type: "loan", amount_usd: 1_520_000_000, lead_investor_ids: [],
      link: Struct.new(:from_organization).new(bank))
    assert_equal "$1.52B loan", DealLine.for(long), "a long lender goes first, never the word loan"
  end
end
