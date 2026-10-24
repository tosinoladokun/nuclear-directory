# A news item for a company's or plant's "Latest" (#137): headline, date,
# publisher, a one-line neutral summary and the link, sourced through
# evidence like any fact. Tosin approves every one before it shows (21 Oct
# 2026: approve each). Mentions say which companies and plants it's about.
class CreateNewsItems < ActiveRecord::Migration[8.1]
  def change
    create_table :news_items do |t|
      t.string :url, null: false
      t.string :title, null: false
      t.string :publisher
      t.date :published_on, null: false
      t.text :summary
      t.decimal :confidence, precision: 3, scale: 2
      t.string :verification_status, default: "pending", null: false
      t.datetime :verified_at
      t.string :verified_by
      t.timestamps
    end

    add_index :news_items, :url, unique: true
    add_index :news_items, :published_on
    add_index :news_items, :verification_status
    add_check_constraint :news_items, "verification_status IN ('pending', 'verified', 'rejected', 'unpublished')",
      name: "news_items_verification_status_check"
    add_check_constraint :news_items, "confidence IS NULL OR confidence >= 0 AND confidence <= 1", name: "news_items_confidence_check"
    add_check_constraint :news_items, "url ~ '^https?://'", name: "news_items_url_check"

    create_table :news_mentions do |t|
      t.references :news_item, null: false, foreign_key: { on_delete: :cascade }
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.timestamps
    end

    add_index :news_mentions, %i[subject_type subject_id]
    add_index :news_mentions, %i[news_item_id subject_type subject_id], unique: true, name: "index_news_mentions_uniqueness"
    add_check_constraint :news_mentions, "subject_type IN ('Organization', 'Facility')", name: "news_mentions_subject_type_check"
  end
end
