# Data Quality's matching actions (#548, option a): what its agent did to a
# claim through the API, with its reason, what the claim looked like before
# (for Undo) and anything it created.
class CreateDqActions < ActiveRecord::Migration[8.1]
  def change
    create_table :dq_actions do |t|
      t.references :candidate, null: false, foreign_key: true
      t.string :action, null: false
      t.string :target
      t.text :reason, null: false
      t.jsonb :before, null: false, default: {}
      t.jsonb :created, null: false, default: []
      t.string :by, null: false
      t.datetime :undone_at
      t.timestamps
    end
    add_index :dq_actions, :created_at
    add_check_constraint :dq_actions, "action IN ('same_as', 'subsidiary_of', 'new', 'close')", name: "dq_actions_action_check"
  end
end
