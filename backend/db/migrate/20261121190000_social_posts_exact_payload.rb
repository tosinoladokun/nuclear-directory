# The exact payload of a graders-approved post (#896 contract): X text sent verbatim (our URL inside it, a handle after), the LinkedIn annotations
# and card it carries, the canonical content hash the graders approved, and the opener pattern it uses (so a repeat inside five posts is refused).
class SocialPostsExactPayload < ActiveRecord::Migration[8.1]
  def change
    add_column :social_posts, :exact_text, :boolean, default: false, null: false
    add_column :social_posts, :annotations, :jsonb
    add_column :social_posts, :card, :jsonb
    add_column :social_posts, :content_payload_sha256, :string
    add_column :social_posts, :opener_pattern_id, :string
  end
end
