# Lets local Metabase's read-only role (#111) read deal terms (#256), which
# were created after the role's grants. SELECT only, on this table only: the
# role is an allow-list (Metabase::ReadonlyRole::READABLE_TABLES), never
# default privileges. Does nothing where the role doesn't exist (tests, CI,
# a fresh database).
class GrantDealTermsToMetabaseReadonly < ActiveRecord::Migration[8.1]
  def up
    Metabase::ReadonlyRole.grant!(%w[deal_terms], connection:)
  end

  def down
    role = Metabase::ReadonlyRole::NAME
    return unless connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = #{connection.quote(role)}")

    execute "REVOKE SELECT ON deal_terms FROM #{connection.quote_column_name(role)}"
  end
end
