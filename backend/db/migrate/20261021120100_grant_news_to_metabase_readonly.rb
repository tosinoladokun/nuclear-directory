# Lets local Metabase's read-only role (#111) read news items and their
# mentions (#137), public once approved like deal terms. SELECT only, on
# these tables only (Metabase::ReadonlyRole::READABLE_TABLES). Does nothing
# where the role doesn't exist (tests, CI, a fresh database).
class GrantNewsToMetabaseReadonly < ActiveRecord::Migration[8.1]
  def up
    Metabase::ReadonlyRole.grant!(%w[news_items news_mentions], connection:)
  end

  def down
    role = Metabase::ReadonlyRole::NAME
    return unless connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{connection.quote(role)}")

    execute "REVOKE SELECT ON news_items, news_mentions FROM #{connection.quote_column_name(role)}"
  end
end
