# A reactor's licensed thermal power in MWt (#721): research reactors are
# licensed by thermal power, from 5 watts (0.000005 MWt) up to 20 MWt, so
# six decimals. capacity_mw stays electrical (MWe).
class AddThermalPowerToFacilities < ActiveRecord::Migration[8.1]
  def change
    add_column :facilities, :thermal_power_mwt, :decimal, precision: 12, scale: 6
    add_check_constraint :facilities, "thermal_power_mwt IS NULL OR thermal_power_mwt > 0", name: "facilities_thermal_power_check"
  end
end
