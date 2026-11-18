# The social agent (#769): each platform's switch, and every post it drafted, checked and sent.
class CreateSocialPosts < ActiveRecord::Migration[8.1]
  def change
    create_table :social_channels do |t|
      t.string :platform, null: false
      # off: nothing runs; drafts: drafted and checked, never sent; live: sent.
      t.string :mode, null: false, default: "off"
      t.timestamps
      t.index :platform, unique: true
      t.check_constraint "platform IN ('x', 'linkedin')", name: "social_channels_platform_check"
      t.check_constraint "mode IN ('off', 'drafts', 'live')", name: "social_channels_mode_check"
    end

    create_table :social_posts do |t|
      t.string :platform, null: false
      t.string :status, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.text :text
      t.string :link
      t.string :source_url
      t.text :source_quote
      # Companies and plants it's about, for the cooldown.
      t.bigint :organization_ids, array: true, null: false, default: []
      t.string :reason
      t.string :external_id
      t.string :permalink
      t.datetime :posted_at
      t.timestamps
      t.index %i[subject_type subject_id]
      t.index %i[platform created_at]
      t.check_constraint "platform IN ('x', 'linkedin')", name: "social_posts_platform_check"
      t.check_constraint "status IN ('drafted', 'posted', 'blocked', 'failed')", name: "social_posts_status_check"
    end
  end
end
