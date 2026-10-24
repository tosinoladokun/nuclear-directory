# EIA's utility ID (#382): the number EIA-860 gives every utility and plant
# owner ("Georgia Power Co" is 7140), as a company identity key, matched
# before any name, as the SEC's CIK is (PM, 18 Oct 2026). EIA-860's
# ownership schedule names owners by it.
class AddEiaUtilityIdToOrganizations < ActiveRecord::Migration[8.1]
  def change
    add_column :organizations, :eia_utility_id, :string
    add_index :organizations, :eia_utility_id, unique: true, where: "eia_utility_id IS NOT NULL"
    add_check_constraint :organizations, "eia_utility_id IS NULL OR eia_utility_id ~ '^[1-9][0-9]{0,6}$'",
      name: "organizations_eia_utility_id_check"
  end
end
