# One form for corrections, suggestions and "Claim or update this listing"
# (#591). A report says what kind it is; a listing update or a new company
# or plant carries its source and its changes, each of which becomes a normal
# claim (candidate_ids). The claimant's details stay here, never public; a
# work email on the company's domain is noted as a signal, never a badge.
class AddListingSubmissions < ActiveRecord::Migration[8.1]
  def change
    change_table :correction_reports, bulk: true do |t|
      t.string :kind, null: false, default: "correction"
      t.string :source_url
      t.string :claimant_name
      t.string :claimant_role
      t.string :claimant_email
      t.boolean :email_domain_match, null: false, default: false
      t.string :record_type
      t.bigint :record_id
      t.jsonb :proposed_changes, null: false, default: []
      t.jsonb :candidate_ids, null: false, default: []
    end
    add_check_constraint :correction_reports, "kind IN ('correction', 'listing', 'new_record', 'new_fact', 'source')", name: "correction_reports_kind_check"
    add_check_constraint :correction_reports, "record_id IS NULL OR record_type IS NOT NULL", name: "correction_reports_record_check"
    # Where a claim came from when it isn't a crawl: "visitor" (#591).
    add_column :candidates, :origin, :string
  end
end
