# Data Quality proposes a sourced role for a company (#548, PM 28 Oct), so a
# new company can reach Tosin with its category.
class AllowProposeRoleDqActions < ActiveRecord::Migration[8.1]
  def up
    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN ('same_as', 'subsidiary_of', 'new', 'close', 'recommend', 'propose_role')", name: "dq_actions_action_check"
  end

  # The audit is never dropped to roll back: with any role recorded, it refuses.
  def down
    if select_value("SELECT 1 FROM dq_actions WHERE action = 'propose_role' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "dq_actions holds propose_role rows (Data Quality's audit); keep them and leave this migration in"
    end

    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN ('same_as', 'subsidiary_of', 'new', 'close', 'recommend')", name: "dq_actions_action_check"
  end
end
