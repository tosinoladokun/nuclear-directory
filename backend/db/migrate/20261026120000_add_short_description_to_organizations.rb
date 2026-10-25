# A company's short description (#559): the middle column of every company
# list row, 40 characters at most (checked in the model). Nullable; until
# Data Quality writes one, rows show role · specialty.
class AddShortDescriptionToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :short_description, :string
  end
end
