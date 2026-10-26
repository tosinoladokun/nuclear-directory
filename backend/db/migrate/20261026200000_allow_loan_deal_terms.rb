# A loan as a deal term (#582): DOE's financing office lends to nuclear
# projects (Palisades, Crane Restart). The lender is the link's "funds" end.
class AllowLoanDealTerms < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :deal_terms, name: "deal_terms_term_type_check"
    add_check_constraint :deal_terms, "term_type IN ('award', 'offtake', 'funding_round', 'loan')", name: "deal_terms_term_type_check"
    # A loan states its amount, as an award does (Database).
    add_check_constraint :deal_terms, "term_type <> 'loan' OR amount_usd IS NOT NULL", name: "deal_terms_loan_check"
  end

  def down
    remove_check_constraint :deal_terms, name: "deal_terms_loan_check"
    remove_check_constraint :deal_terms, name: "deal_terms_term_type_check"
    add_check_constraint :deal_terms, "term_type IN ('award', 'offtake', 'funding_round')", name: "deal_terms_term_type_check"
  end
end
