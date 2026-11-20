# Data Quality reads leads in Metabase without seeing what visitors searched
# (PM, 20 Nov): a view of every lead some other source named, with the search
# sightings taken out of its sources (Metabase::ReadonlyRole::VIEW_SQL). The
# leads table stays private; the role reads only the view. Search counts stay
# in seen_count, never the words. schema.rb doesn't keep views, so the role's
# apply! creates it again on a database loaded from it.
class CreateMetabaseLeadsView < ActiveRecord::Migration[8.1]
  def up
    Metabase::ReadonlyRole.create_views!(connection:)
    Metabase::ReadonlyRole.grant!(%w[metabase_leads], connection:)
  end

  def down
    execute "DROP VIEW IF EXISTS metabase_leads"
  end
end
