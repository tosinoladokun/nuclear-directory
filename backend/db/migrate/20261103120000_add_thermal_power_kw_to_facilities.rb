# A reactor's licensed thermal power in kW, as NRC states it ("Power Level
# (kW): 6,000"), so the value matches its quote (#721). Research reactors run
# from a few watts (0.005 kW) to 20,000 kW, so four decimals. capacity_mw
# stays electrical (MWe).
class AddThermalPowerKwToFacilities < ActiveRecord::Migration[8.1]
  def change
    add_column :facilities, :thermal_power_kw, :decimal, precision: 12, scale: 4
    add_check_constraint :facilities, "thermal_power_kw IS NULL OR thermal_power_kw > 0", name: "facilities_thermal_power_check"
  end
end
