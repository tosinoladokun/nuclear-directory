# Admin on/off switches (#998). The first is "dq_pass": Data Quality's daily
# pass on the server. It ships off, so its first live night is a deliberate
# switch-on in Admin > Health. A missing row reads as off.
class CreateSwitches < ActiveRecord::Migration[8.1]
  def change
    create_table :switches do |t|
      t.string :key, null: false
      t.boolean :on, null: false, default: false
      t.string :changed_by
      t.timestamps
    end
    add_index :switches, :key, unique: true
  end
end
