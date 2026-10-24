# Searches on the site that found nothing (#483), so missing companies and
# plants become a worklist. Only the normalised query, when and how often:
# nothing about who searched.
class CreateSearchGaps < ActiveRecord::Migration[8.1]
  def change
    create_table :search_gaps do |t|
      t.string :query, null: false
      t.integer :searches_count, null: false, default: 1
      t.date :first_searched_on, null: false
      t.date :last_searched_on, null: false
      t.string :status, null: false, default: "open"
      t.string :decided_by
      t.datetime :decided_at
      t.datetime :closed_at
      t.timestamps
    end

    add_index :search_gaps, :query, unique: true
    add_index :search_gaps, %i[status searches_count]
    add_check_constraint :search_gaps, "status IN ('open', 'research', 'covered', 'ignored', 'closed')", name: "search_gaps_status_check"
    add_check_constraint :search_gaps, "searches_count >= 1", name: "search_gaps_count_check"
    add_check_constraint :search_gaps, "char_length(query) BETWEEN 3 AND 100", name: "search_gaps_query_length_check"
  end
end
