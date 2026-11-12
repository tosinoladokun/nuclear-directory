# Enrich's deep look (#758): a person's Enrich click reads deeper (more of the
# company's own pages, plus awards, projects, NRC documents and releases by
# name) than the nightly gap fill, which shares enrich_requested_at. Set by a
# click, cleared once the read is done.
class AddEnrichDeepToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :enrich_deep, :boolean, default: false, null: false
  end
end
