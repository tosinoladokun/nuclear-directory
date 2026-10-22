# Enrich (#479): the admin asks for one company's own pages to be read
# against the fixed field list; enrich_requested_at is when, enriched_at
# when its pages were last read for it. exchange and ticker: a public
# company's stock listing (NASDAQ: OKLO), sourced like any field.
class AddEnrichAndListingToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :enrich_requested_at, :datetime
    add_column :organizations, :enriched_at, :datetime
    add_column :organizations, :exchange, :string
    add_column :organizations, :ticker, :string

    add_index :organizations, :enrich_requested_at, where: "enrich_requested_at IS NOT NULL"
    add_index :organizations, %i[exchange ticker], unique: true, where: "ticker IS NOT NULL"
    add_check_constraint :organizations, "exchange IS NULL OR exchange IN ('NASDAQ', 'NYSE', 'NYSE American', 'TSX', 'TSXV', 'LSE', 'ASX', 'OTC')",
      name: "organizations_exchange_check"
    add_check_constraint :organizations, "(exchange IS NULL) = (ticker IS NULL)", name: "organizations_listing_check"
  end
end
