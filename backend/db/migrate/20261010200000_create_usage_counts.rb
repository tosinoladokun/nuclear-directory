# Anonymous daily counters (#45): page views per path and searches per
# normalized query. One row per (day, event, key); nothing about the visitor.
class CreateUsageCounts < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_counts do |t|
      t.date :day, null: false
      t.string :event, null: false
      t.string :key, null: false
      t.integer :count, null: false, default: 0
      t.timestamps

      t.index [ :day, :event, :key ], unique: true
      t.index [ :event, :day ]
      t.check_constraint "event IN ('page_view', 'search', 'search_no_results')", name: "usage_counts_event_check"
      t.check_constraint "count >= 0", name: "usage_counts_count_check"
    end
  end
end
