# The admin's Today page (#373): which of the day's four steps the admin
# has finished, so the plan reads the same on phone and desktop. One row per
# day and step, written when a step is marked done, removed by Undo. Steps 3
# and 4 finish by themselves when nothing is left, so only steps 1 and 2 are
# usually stored; 3 and 4 are stored only if the admin closes them by hand.
class CreateTodaySteps < ActiveRecord::Migration[8.1]
  def change
    create_table :today_steps do |t|
      t.date :on, null: false
      t.string :step, null: false
      t.string :done_by, null: false
      # How it was finished, when that matters: "no_list" (no list from Data Quality today).
      t.string :note
      t.timestamps
    end
    add_index :today_steps, [ :on, :step ], unique: true
    add_check_constraint :today_steps, "step IN ('crawl', 'list', 'review', 'left')", name: "today_steps_step_check"
    add_check_constraint :today_steps, "done_by LIKE 'human:%'", name: "today_steps_done_by_check"
  end
end
