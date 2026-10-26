# Data Quality's matching actions (#548, option a): what its agent did to a
# claim through the API, with its reason, the claim as it was (for Undo) and
# what it created. Shape from Database's review.
class CreateDqActions < ActiveRecord::Migration[8.1]
  def change
    create_table :dq_actions do |t|
      t.references :candidate, null: false, foreign_key: true, index: true
      t.string :action, null: false
      # The company it's the same as, or the parent (same_as, subsidiary_of).
      t.string :target_type
      t.bigint :target_id
      t.text :reason, null: false
      t.jsonb :before, null: false
      t.jsonb :created, null: false, default: []
      # The claim as the action left it, so Undo refuses once it changed.
      t.jsonb :after, null: false, default: {}
      t.string :by, null: false
      # Sent with a row, so a retried request never applies twice.
      t.string :request_key
      t.datetime :undone_at
      t.string :undone_by
      t.datetime :created_at, null: false
    end
    add_index :dq_actions, :created_at, order: { created_at: :desc }
    add_index :dq_actions, :request_key, unique: true, where: "request_key IS NOT NULL"
    add_check_constraint :dq_actions, "action IN ('same_as', 'subsidiary_of', 'new', 'close')", name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "(target_type IS NULL) = (target_id IS NULL)", name: "dq_actions_target_check"
    add_check_constraint :dq_actions, "char_length(btrim(reason)) > 0", name: "dq_actions_reason_check"
    add_check_constraint :dq_actions, "by LIKE 'agent:%' OR by LIKE 'human:%'", name: "dq_actions_by_check"
  end
end
