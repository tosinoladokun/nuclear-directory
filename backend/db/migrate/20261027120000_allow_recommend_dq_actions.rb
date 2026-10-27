# Data Quality's verdicts through its endpoint (#548): "recommend" records
# approve or reject with a reason on a waiting claim, as the paste box does.
class AllowRecommendDqActions < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN ('same_as', 'subsidiary_of', 'new', 'close', 'recommend')", name: "dq_actions_action_check"
  end

  # The audit is never dropped to roll back: with any verdict recorded, it refuses.
  def down
    if select_value("SELECT 1 FROM dq_actions WHERE action = 'recommend' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "dq_actions holds recommend rows (Data Quality's audit); keep them and leave this migration in"
    end

    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN ('same_as', 'subsidiary_of', 'new', 'close')", name: "dq_actions_action_check"
  end
end
