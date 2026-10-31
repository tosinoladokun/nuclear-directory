# Data Quality proposes sourced values for a published company's website,
# description, short description or HQ (PM, 30 Oct: complete companies).
class AllowProposeFieldsDqActions < ActiveRecord::Migration[8.1]
  BEFORE = %w[same_as subsidiary_of new close recommend propose_role].freeze

  def up
    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN (#{(BEFORE + %w[propose_fields]).map { |a| "'#{a}'" }.join(', ')})", name: "dq_actions_action_check"
  end

  # The audit is never dropped to roll back: with any propose_fields row, it refuses.
  def down
    if select_value("SELECT 1 FROM dq_actions WHERE action = 'propose_fields' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "dq_actions holds propose_fields rows (Data Quality's audit); keep them and leave this migration in"
    end

    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN (#{BEFORE.map { |a| "'#{a}'" }.join(', ')})", name: "dq_actions_action_check"
  end
end
