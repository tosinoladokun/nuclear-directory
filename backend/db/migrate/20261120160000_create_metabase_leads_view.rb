# Data Quality reads leads in Metabase without seeing what visitors searched
# (PM, 20 Nov): a view of every lead some other source named, with the search
# sightings taken out of its sources. The leads table stays private; the role
# reads only the view. Search counts stay in seen_count, never the words.
class CreateMetabaseLeadsView < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE VIEW metabase_leads AS
      SELECT l.id, l.name, l.normalized_name, l.kind,
             (SELECT jsonb_agg(s) FROM jsonb_array_elements(l.sources) s WHERE s->>'key' NOT LIKE 'search:%') AS sources,
             l.first_seen_on, l.last_seen_on, l.seen_count, l.status, l.reason, l.record_type, l.record_id, l.note,
             l.decided_by, l.decided_at, l.find_attempts, l.next_find_at, l.candidate_id, l.created_at, l.updated_at
      FROM leads l
      WHERE EXISTS (SELECT 1 FROM jsonb_array_elements(l.sources) s WHERE s->>'key' NOT LIKE 'search:%')
    SQL
    Metabase::ReadonlyRole.grant!(%w[metabase_leads], connection:)
  end

  def down
    execute "DROP VIEW IF EXISTS metabase_leads"
  end
end
