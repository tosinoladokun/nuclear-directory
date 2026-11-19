# The autopilot's open alerts (#811): one row per alert key, kept until it's resolved, so a stall that lasts for days
# is reminded once a day and its recovery is still said when it clears (the cache forgets after a day).
class CreateAutopilotAlerts < ActiveRecord::Migration[8.1]
  def change
    create_table :autopilot_alerts do |t|
      t.string :key, null: false
      t.string :title, null: false
      t.datetime :opened_at, null: false
      t.datetime :last_emailed_at
      t.datetime :last_reported_at
      t.datetime :resolved_at
      t.timestamps
      t.index :key, unique: true
    end
  end
end
