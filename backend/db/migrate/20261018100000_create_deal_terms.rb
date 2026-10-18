# One award, offtake or funding round under the link it belongs to (#256):
# "U.S. Department of Energy funds X-energy" is a link; each DOE award to
# X-energy is a deal term, with its own amount, dates and source. A fact like
# any other: verified by a human, sourced through evidence, audited.
class CreateDealTerms < ActiveRecord::Migration[8.1]
  def change
    create_table :deal_terms do |t|
      t.string :link_type, null: false
      t.bigint :link_id, null: false
      t.string :term_type, null: false
      t.string :external_id
      t.decimal :amount_usd, precision: 16, scale: 2
      t.decimal :capacity_mw, precision: 10, scale: 1
      t.date :signed_on
      t.date :starts_on
      t.date :ends_on
      t.string :status
      t.string :program
      t.string :round
      t.bigint :lead_investor_ids, array: true, default: [], null: false
      t.decimal :confidence, precision: 3, scale: 2
      t.string :verification_status, default: "pending", null: false
      t.datetime :verified_at
      t.string :verified_by
      t.timestamps
    end

    add_index :deal_terms, %i[link_type link_id]
    add_index :deal_terms, %i[link_type link_id term_type external_id], unique: true, where: "external_id IS NOT NULL",
      name: "index_deal_terms_uniqueness"
    add_index :deal_terms, :verification_status

    add_check_constraint :deal_terms, "link_type IN ('Relationship', 'FacilityRelationship')", name: "deal_terms_link_type_check"
    add_check_constraint :deal_terms, "term_type IN ('award', 'offtake', 'funding_round')", name: "deal_terms_term_type_check"
    add_check_constraint :deal_terms, "status IS NULL OR status IN ('announced', 'signed', 'active', 'completed', 'terminated')",
      name: "deal_terms_status_check"
    add_check_constraint :deal_terms, "verification_status IN ('pending', 'verified', 'rejected', 'unpublished')",
      name: "deal_terms_verification_status_check"
    add_check_constraint :deal_terms, "confidence IS NULL OR confidence >= 0 AND confidence <= 1", name: "deal_terms_confidence_check"
    add_check_constraint :deal_terms, "amount_usd IS NULL OR amount_usd >= 0", name: "deal_terms_amount_check"
    add_check_constraint :deal_terms, "capacity_mw IS NULL OR capacity_mw >= 0", name: "deal_terms_capacity_check"
    add_check_constraint :deal_terms, "ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on", name: "deal_terms_dates_check"
    # What each kind needs to mean anything.
    add_check_constraint :deal_terms,
      "term_type <> 'award' OR (amount_usd IS NOT NULL AND starts_on IS NOT NULL AND external_id IS NOT NULL)",
      name: "deal_terms_award_check"
    add_check_constraint :deal_terms, "term_type <> 'offtake' OR capacity_mw IS NOT NULL OR amount_usd IS NOT NULL",
      name: "deal_terms_offtake_check"
    add_check_constraint :deal_terms, "term_type <> 'funding_round' OR amount_usd IS NOT NULL OR round IS NOT NULL",
      name: "deal_terms_round_check"
  end
end
