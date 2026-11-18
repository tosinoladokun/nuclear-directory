# Data Quality proposes a sourced link between two companies (PM, 18 Nov: Cameco's stake in Westinghouse).
class AllowProposeLinkDqActions < ActiveRecord::Migration[8.1]
  BEFORE = %w[same_as subsidiary_of new close recommend propose_role propose_fields].freeze

  def up
    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN (#{(BEFORE + %w[propose_link]).map { |a| "'#{a}'" }.join(', ')})", name: "dq_actions_action_check"
  end

  # The audit is never dropped to roll back: with any propose_link row, it refuses.
  def down
    if select_value("SELECT 1 FROM dq_actions WHERE action = 'propose_link' LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "dq_actions holds propose_link rows (Data Quality's audit); keep them and leave this migration in"
    end

    remove_check_constraint :dq_actions, name: "dq_actions_action_check"
    add_check_constraint :dq_actions, "action IN (#{BEFORE.map { |a| "'#{a}'" }.join(', ')})", name: "dq_actions_action_check"
  end
end
