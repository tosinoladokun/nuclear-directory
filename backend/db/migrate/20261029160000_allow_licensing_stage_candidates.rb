# A licensing stage as a claim (#650): the NRC ADAMS reader proposes a
# developer's pre-application docket for a person to approve. Adds
# licensing_stage to whatever kinds the constraint allows when it runs, and
# takes only it away on rollback, so it composes with other PRs adding kinds.
class AllowLicensingStageCandidates < ActiveRecord::Migration[8.1]
  KIND = "licensing_stage"

  def up = replace(current_kinds | [ KIND ])

  def down
    if select_value("SELECT 1 FROM candidates WHERE kind = #{connection.quote(KIND)} LIMIT 1")
      raise ActiveRecord::IrreversibleMigration, "candidates holds licensing_stage claims; keep them and leave this migration in"
    end

    replace(current_kinds - [ KIND ])
  end

  private
    def current_kinds
      definition = select_value("SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'candidates_kind_check'").to_s
      definition.scan(/'([a-z_]+)'/).flatten.uniq
    end

    def replace(kinds)
      remove_check_constraint :candidates, name: "candidates_kind_check"
      add_check_constraint :candidates, "kind IN (#{kinds.map { |kind| connection.quote(kind) }.join(', ')})", name: "candidates_kind_check"
    end
end
