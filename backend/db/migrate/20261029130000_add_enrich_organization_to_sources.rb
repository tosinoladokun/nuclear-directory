# Enrich (#534): the company a page was last read for, so companies that
# share one website (seeded with no domain) get their own findings, and a
# company that owns the domain doesn't receive them. Additive; a company's
# removal leaves the page and forgets whose it was.
class AddEnrichOrganizationToSources < ActiveRecord::Migration[8.1]
  def change
    add_reference :sources, :enrich_organization, foreign_key: { to_table: :organizations, on_delete: :nullify }, index: true
  end
end
