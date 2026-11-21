# Data Quality's proposals to take a public fact off (#863 part 2): one Yes or
# No for Tosin in Today, grouped by batch. Yes unpublishes it (reversible with
# Put back); No keeps it. Nothing is ever deleted.
class CreateTakeoffProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :takeoff_proposals do |t|
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.string :batch, null: false
      t.text :reason, null: false
      t.string :source_url
      t.text :quote
      t.string :proposed_by, null: false
      t.string :status, null: false, default: "pending"
      t.string :decided_by
      t.datetime :decided_at
      t.timestamps
      t.index %i[status batch]
      t.index %i[subject_type subject_id]
      t.check_constraint "status IN ('pending', 'taken_off', 'kept')", name: "takeoff_proposals_status_check"
    end
  end
end
