# A deal term's form of agreement (#256, for the data piece #255): what
# kind of document it is, so a signed power deal can be counted and a
# framework or MOU listed by its stage from data, not from the link's
# description (docs/DATA.md section 2). Optional: awards and rounds have none.
class AddAgreementToDealTerms < ActiveRecord::Migration[8.1]
  AGREEMENTS = %w[ppa supply_agreement tariff_subscription development_agreement framework mou loi option preorder].freeze

  def change
    add_column :deal_terms, :agreement, :string
    add_check_constraint :deal_terms, "agreement IS NULL OR agreement IN (#{AGREEMENTS.map { |a| "'#{a}'" }.join(', ')})",
      name: "deal_terms_agreement_check"
  end
end
