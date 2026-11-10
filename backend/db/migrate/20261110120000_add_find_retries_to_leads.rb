# One lead pipeline (#752, Tosin 10 Nov): a lead the finder couldn't confirm
# is tried again weekly for a month, then closed. How many tries so far, and
# when the next is due.
class AddFindRetriesToLeads < ActiveRecord::Migration[8.1]
  def change
    add_column :leads, :find_attempts, :integer, default: 0, null: false
    add_column :leads, :next_find_at, :datetime
    add_check_constraint :leads, "find_attempts >= 0", name: "leads_find_attempts_check"
  end
end
