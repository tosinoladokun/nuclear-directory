# Automated data steps on deploy (#301, bin/deploy-data). data_deploys: one
# row per run that wrote or tried to, with what it read and found.
# data_migrations: the one-off data fixes in db/data/, each run once.
class CreateDataDeploys < ActiveRecord::Migration[8.1]
  def change
    create_table :data_deploys do |t|
      t.string :commit
      t.string :status, null: false
      # Hash of the seed files and the code that loads them, and each file's
      # own hash, so the next run knows which files changed.
      t.string :seed_digest
      t.jsonb :files, default: {}, null: false
      t.string :backup_tag
      t.jsonb :report, default: {}, null: false
      t.text :error
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.index [ :status, :id ]
    end

    create_table :data_migrations do |t|
      t.string :version, null: false
      t.string :name, null: false
      t.string :by, null: false
      t.text :reason
      t.string :commit
      t.text :output
      t.datetime :ran_at, null: false
      t.index :version, unique: true
    end
  end
end
