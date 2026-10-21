# What the data piece (#255) needs to count and describe a power deal from
# data, not from the link's description (#256, docs/DATA.md section 2):
# - agreement: the form of agreement; a framework or MOU is listed by stage
# - conditions: what a signed deal still waits for ("NRC approval"); a deal
#   with one isn't counted yet
# - firm_mw: MW firmly contracted, when the source states it (capacity_mw is
#   the headline figure); blank means not stated, never estimated
# - term_years: the contract's length, when a source gives no dates
# All optional: awards and rounds have none of them.
class AddAgreementToDealTerms < ActiveRecord::Migration[8.1]
  AGREEMENTS = %w[ppa supply_agreement tariff_subscription development_agreement prepayment framework mou loi option preorder].freeze

  COUNTED = %w[ppa supply_agreement tariff_subscription].freeze

  def change
    add_column :deal_terms, :agreement, :string
    add_column :deal_terms, :conditions, :text
    add_column :deal_terms, :firm_mw, :decimal, precision: 10, scale: 1
    add_column :deal_terms, :term_years, :integer
    add_check_constraint :deal_terms, "agreement IS NULL OR agreement IN (#{AGREEMENTS.map { |a| "'#{a}'" }.join(', ')})",
      name: "deal_terms_agreement_check"
    add_check_constraint :deal_terms, "firm_mw IS NULL OR firm_mw >= 0", name: "deal_terms_firm_mw_check"
    add_check_constraint :deal_terms, "term_years IS NULL OR term_years > 0", name: "deal_terms_term_years_check"

    # An offtake states its size, unless it's listed by stage (a framework,
    # an option…): then a size its source doesn't give stays blank.
    remove_check_constraint :deal_terms, "term_type::text <> 'offtake'::text OR capacity_mw IS NOT NULL OR amount_usd IS NOT NULL",
      name: "deal_terms_offtake_check"
    add_check_constraint :deal_terms, "term_type::text <> 'offtake'::text OR capacity_mw IS NOT NULL OR amount_usd IS NOT NULL " \
      "OR (agreement IS NOT NULL AND agreement NOT IN (#{COUNTED.map { |a| "'#{a}'" }.join(', ')}))", name: "deal_terms_offtake_check"
  end
end
