# The monthly open dataset release (#950): each version's draft, built from
# production, and what publishing it did. The files sit in their own table,
# gzipped, so the admin list never loads them.
class CreateDatasetReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :dataset_releases do |t|
      t.string :version, null: false
      t.string :status, null: false, default: "draft"
      t.string :tables_included, array: true, null: false, default: []
      t.jsonb :counts, null: false, default: {}
      t.string :previous_version
      t.jsonb :previous_counts
      t.text :changelog
      t.string :unknown_publishers, array: true, null: false, default: []
      t.datetime :built_at
      t.datetime :published_at
      t.string :commit_sha
      t.string :release_url
      t.string :version_doi
      t.text :error
      t.jsonb :dry_run
      t.timestamps
    end
    add_index :dataset_releases, :version, unique: true
    add_check_constraint :dataset_releases, "status IN ('draft', 'published', 'failed')", name: "dataset_releases_status"

    create_table :dataset_release_files do |t|
      t.references :dataset_release, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :path, null: false
      t.binary :content_gz, null: false
      t.integer :bytes, null: false
      t.string :git_sha, null: false
      t.timestamps
    end
    add_index :dataset_release_files, %i[dataset_release_id path], unique: true
  end
end
