# Each IndexNow batch and whether the engines accepted it (#811: it was refused 13 to 19 Nov and nobody knew).
class CreateIndexNowSubmissions < ActiveRecord::Migration[8.1]
  def change
    create_table :index_now_submissions do |t|
      t.integer :urls, null: false
      t.boolean :accepted, null: false
      t.datetime :created_at, null: false
      t.index :created_at
    end
  end
end
