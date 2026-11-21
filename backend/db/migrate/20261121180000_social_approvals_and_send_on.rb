# Graders-approved drafts (#896): the day a draft is meant to go out (the 8:30 job sends it, #897), what the content checks said when it was
# handed over (shown on its row), and Data Quality's recorded approval of an exact hash, which the approved-drafts endpoint requires.
class SocialApprovalsAndSendOn < ActiveRecord::Migration[8.1]
  def change
    add_column :social_posts, :send_on, :date
    add_column :social_posts, :warnings, :text
    add_column :social_posts, :approved_sha256, :string
    add_index :social_posts, %i[platform send_on], where: "send_on IS NOT NULL", name: "index_social_posts_on_platform_and_send_on"

    create_table :social_approvals do |t|
      t.string :platform, null: false
      t.string :slug, null: false
      t.string :sha256, null: false
      t.string :approved_by, null: false
      t.text :note
      t.timestamps
    end
    add_index :social_approvals, %i[platform slug sha256], unique: true
    add_check_constraint :social_approvals, "platform IN ('x', 'linkedin')", name: "social_approvals_platform_check"
    add_check_constraint :social_approvals, "sha256 ~ '^[0-9a-f]{64}$'", name: "social_approvals_sha256_check"
  end
end
