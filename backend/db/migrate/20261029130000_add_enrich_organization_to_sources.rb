# Enrich (#534): the company a page was last read for, so companies that
# share one website (seeded with no domain) get their own findings, and a
# company that owns the domain doesn't receive them. Additive; a company's
# removal leaves the page and forgets whose it was.
class AddEnrichOrganizationToSources < ActiveRecord::Migration[8.1]
  # sources is large: the index is built without locking the crawl's writes,
  # and the foreign key is validated in its own step (Database, 29 Oct).
  disable_ddl_transaction!

  def up
    add_column :sources, :enrich_organization_id, :bigint, if_not_exists: true
    add_index :sources, :enrich_organization_id, algorithm: :concurrently, if_not_exists: true
    unless foreign_key_exists?(:sources, :organizations, column: :enrich_organization_id)
      add_foreign_key :sources, :organizations, column: :enrich_organization_id, on_delete: :nullify, validate: false
    end
    validate_foreign_key :sources, :organizations, column: :enrich_organization_id
  end

  def down
    remove_foreign_key :sources, :organizations, column: :enrich_organization_id, if_exists: true
    remove_index :sources, :enrich_organization_id, algorithm: :concurrently, if_exists: true
    remove_column :sources, :enrich_organization_id, if_exists: true
  end
end
