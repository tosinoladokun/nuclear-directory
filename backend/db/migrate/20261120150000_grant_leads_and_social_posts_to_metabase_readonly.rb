# Lets local Metabase's read-only role read leads and social posts, so Data
# Quality can count and audit them (PM, 20 Nov). Neither holds a secret or a
# person's contact: social posts are the agent's drafts and sends; leads are
# names, where they were seen, and a visitor's search text when that's where
# a name came from (no IP or visitor id). SELECT only, on these two tables.
# Does nothing where the role doesn't exist (tests, CI, a fresh database).
class GrantLeadsAndSocialPostsToMetabaseReadonly < ActiveRecord::Migration[8.1]
  TABLES = %w[leads social_posts].freeze

  def up
    Metabase::ReadonlyRole.grant!(TABLES, connection:)
  end

  def down
    role = Metabase::ReadonlyRole::NAME
    return unless connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{connection.quote(role)}")

    TABLES.each { |table| execute "REVOKE SELECT ON #{table} FROM #{connection.quote_column_name(role)}" }
  end
end
