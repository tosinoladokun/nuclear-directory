# SEC EDGAR (#129): a company's SEC CIK as an identity key, and a Form D
# round as a deal term on the company itself (PM, 18 Oct 2026). A Form D
# names no investors, so the round can't hang off a link; an investor named
# by another primary source is a separate funds or invests_in link.
class AddSecFields < ActiveRecord::Migration[8.1]
  def up
    add_column :organizations, :sec_cik, :string
    add_index :organizations, :sec_cik, unique: true, where: "sec_cik IS NOT NULL"
    add_check_constraint :organizations, "sec_cik IS NULL OR sec_cik ~ '^[0-9]{10}$'", name: "organizations_sec_cik_check"

    add_column :deal_terms, :amount_offered_usd, :decimal, precision: 16, scale: 2
    add_check_constraint :deal_terms, "amount_offered_usd IS NULL OR amount_offered_usd >= 0", name: "deal_terms_amount_offered_check"
    remove_check_constraint :deal_terms, name: "deal_terms_link_type_check"
    add_check_constraint :deal_terms, "link_type IN ('Relationship', 'FacilityRelationship', 'Organization')", name: "deal_terms_link_type_check"
    add_check_constraint :deal_terms, "link_type <> 'Organization' OR term_type = 'funding_round'", name: "deal_terms_company_round_check"
  end

  def down
    remove_check_constraint :deal_terms, name: "deal_terms_company_round_check"
    remove_check_constraint :deal_terms, name: "deal_terms_link_type_check"
    add_check_constraint :deal_terms, "link_type IN ('Relationship', 'FacilityRelationship')", name: "deal_terms_link_type_check"
    remove_check_constraint :deal_terms, name: "deal_terms_amount_offered_check"
    remove_column :deal_terms, :amount_offered_usd
    remove_check_constraint :organizations, name: "organizations_sec_cik_check"
    remove_index :organizations, :sec_cik
    remove_column :organizations, :sec_cik
  end
end
