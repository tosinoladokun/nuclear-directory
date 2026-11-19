# The pipeline's daily health (#811): one row a day of per-stage counts, so a stall over days can be seen.
class CreatePipelineHealthSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :pipeline_health_snapshots do |t|
      t.date :on, null: false
      t.jsonb :counts, null: false, default: {}
      t.jsonb :problems, null: false, default: []
      t.timestamps
      t.index :on, unique: true
    end
  end
end
