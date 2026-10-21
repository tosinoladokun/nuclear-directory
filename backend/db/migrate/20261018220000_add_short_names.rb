# A short display name for companies and plants ("Oglethorpe", "MEAG",
# "DOE"), for the one-line law in tight spots: the connections map, home
# lists, chips, crumbs (PM, 18 Oct 2026). A display label only: never an
# identity key, never matched on.
class AddShortNames < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :short_name, :string
    add_column :facilities, :short_name, :string
    add_check_constraint :organizations, "short_name IS NULL OR char_length(short_name) BETWEEN 1 AND 30", name: "organizations_short_name_check"
    add_check_constraint :facilities, "short_name IS NULL OR char_length(short_name) BETWEEN 1 AND 30", name: "facilities_short_name_check"
  end
end
