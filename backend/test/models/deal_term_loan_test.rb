require "test_helper"

# #582: a loan is a deal term on a "funds" link: an amount, and its program
# and term when the source states them.
class DealTermLoanTest < ActiveSupport::TestCase
  setup do
    doe = Organization.create!(name: "Loan Lender Co", short_name: "DOE", verification_status: "verified", verified_by: "human:tosin")
    holtec = Organization.create!(name: "Loan Borrower Co", verification_status: "verified", verified_by: "human:tosin")
    @link = Relationship.create!(from_organization: doe, to_organization: holtec, relationship_type: "funds", verification_status: "verified", verified_by: "human:tosin")
  end

  test "a loan needs an amount, and reads as amount, lender, loan" do
    assert_not DealTerm.new(link: @link, term_type: "loan").valid?
    loan = DealTerm.create!(link: @link, term_type: "loan", amount_usd: 1_520_000_000, program: "Energy Dominance Financing", term_years: 30)
    assert_equal "$1.52B DOE loan", DealLine.for(loan)
  end

  test "the database refuses a loan without an amount" do
    loan = DealTerm.create!(link: @link, term_type: "loan", amount_usd: 1_000_000)
    assert_raises(ActiveRecord::StatementInvalid) { DealTerm.transaction(requires_new: true) { loan.update_columns(amount_usd: nil) } }
  end
end
