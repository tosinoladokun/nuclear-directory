# A company's country is a fact like any other: set only when a source
# states it (DATA.md; the dataset's own column note says so). The column's
# "US" default gave every company a crawler created a country with no source
# (Data Quality, 24 Oct). New companies now start blank. Existing values are
# left alone: which of them a source states is Data Quality's call.
class NoDefaultCountryForOrganizations < ActiveRecord::Migration[8.1]
  def change
    change_column_default :organizations, :country_code, from: "US", to: nil
  end
end
