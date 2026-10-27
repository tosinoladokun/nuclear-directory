# Leads triage (Tosin, 27 Oct: "people are searching rubbish"): a lead seen
# only in site searches waits in triage, not To do. Existing ones move there;
# headlines saved as names by the old trade-press feed are set aside
# (ignored, with why), never deleted.
class AddTriageToLeads < ActiveRecord::Migration[8.1]
  STATUSES = %w[triage new researching added ignored].freeze
  HEADLINE = "A headline, not a name: it stays in the news queue".freeze

  def up
    remove_check_constraint :leads, name: "leads_status_check"
    add_check_constraint :leads, "status IN (#{STATUSES.map { |s| "'#{s}'" }.join(', ')})", name: "leads_status_check"

    # Only searches, still To do: triage.
    execute <<~SQL.squish
      UPDATE leads SET status = 'triage', updated_at = NOW()
      WHERE status = 'new' AND jsonb_array_length(sources) > 0 AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(sources) s WHERE s->>'key' IS NULL OR s->>'key' NOT LIKE 'search:%')
    SQL
    # Only trade-press headlines, still To do: set aside with why.
    execute <<~SQL.squish
      UPDATE leads SET status = 'ignored', reason = #{quote(HEADLINE)}, decided_by = 'agent:backend',
        decided_at = NOW(), updated_at = NOW()
      WHERE status = 'new' AND jsonb_array_length(sources) > 0 AND NOT EXISTS (
        SELECT 1 FROM jsonb_array_elements(sources) s WHERE s->>'key' IS NULL OR s->>'key' NOT LIKE 'trade_press:%')
    SQL
  end

  def down
    execute "UPDATE leads SET status = 'new', updated_at = NOW() WHERE status = 'triage'"
    # The headlines this step set aside go back to To do as they were.
    execute <<~SQL.squish
      UPDATE leads SET status = 'new', reason = NULL, decided_by = NULL, decided_at = NULL, updated_at = NOW()
      WHERE status = 'ignored' AND decided_by = 'agent:backend' AND reason = #{quote(HEADLINE)}
    SQL
    remove_check_constraint :leads, name: "leads_status_check"
    add_check_constraint :leads, "status IN ('new', 'researching', 'added', 'ignored')", name: "leads_status_check"
  end
end
