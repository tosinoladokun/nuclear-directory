require "test_helper"

# The role Metabase reads production with (#111): reads work, writes and
# sign-in data don't. It runs outside a transaction, since the role's own
# connection must see the grants, and drops the role afterwards.
class Metabase::ReadonlyRoleTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  PASSWORD = "test-only-password-not-real-0123456789".freeze

  setup do
    @name = "metabase_ro_test_#{Process.pid}"
    Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD)
  end

  teardown do
    @session&.close
    connection = ActiveRecord::Base.connection
    role = connection.quote_column_name(@name)
    connection.execute("DROP TABLE IF EXISTS metabase_later_table")
    connection.execute("DROP OWNED BY #{role}")
    connection.execute("DROP ROLE IF EXISTS #{role}")
  end

  def session
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    @session ||= PG.connect(host: config[:host] || "localhost", port: config[:port], dbname: ActiveRecord::Base.connection.current_database,
      user: @name, password: PASSWORD)
  end

  def refused(sql)
    error = assert_raises(PG::Error) { session.exec(sql) }
    session.exec("ROLLBACK") if session.transaction_status != PG::PQTRANS_IDLE
    error
  end

  test "it reads the directory but can't write, change the schema or read sign-in data" do
    assert_equal "0", session.exec("SELECT count(*) FROM organizations WHERE slug = 'none'").getvalue(0, 0)

    assert_match "read-only transaction", refused("INSERT INTO organizations (name, slug, country_code, created_at, updated_at) " \
      "VALUES ('X', 'x', 'US', now(), now())").message
    assert_match "read-only transaction", refused("UPDATE organizations SET name = 'X'").message
    assert_match "read-only transaction", refused("DELETE FROM organizations").message
    assert_match "read-only transaction", refused("CREATE TABLE metabase_probe (id int)").message
    %w[users sessions correction_reports solid_queue_jobs solid_cache_entries].each do |table|
      assert_match "permission denied", refused("SELECT * FROM #{table}").message, table
    end
  end

  test "Render's owner, which can create roles but isn't a superuser, can set the role up" do
    owner = "metabase_owner_test_#{Process.pid}"
    connection = ActiveRecord::Base.connection
    drop = ->(name) { connection.execute("DROP OWNED BY #{name}") if connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = '#{name}'"); connection.execute("DROP ROLE IF EXISTS #{name}") }
    drop.(@name)
    connection.execute("CREATE ROLE #{owner} LOGIN CREATEROLE PASSWORD #{connection.quote(PASSWORD)}")
    config = ActiveRecord::Base.connection_db_config.configuration_hash
    as_owner = PG.connect(host: config[:host] || "localhost", port: config[:port], dbname: connection.current_database,
      user: owner, password: PASSWORD)

    Metabase::ReadonlyRole.account_statements(name: @name, password: PASSWORD, connection:).each { |sql| as_owner.exec(sql) }

    assert_equal "1", session.exec("SELECT 1").getvalue(0, 0), "the role signs in"
  ensure
    as_owner&.close
    @session&.close
    @session = nil
    drop.(@name)
    drop.(owner)
    Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD)
  end

  test "an existing role with unsafe attributes is refused, not reused" do
    ActiveRecord::Base.connection.execute("ALTER ROLE #{ActiveRecord::Base.connection.quote_column_name(@name)} CREATEDB")

    error = assert_raises(Metabase::ReadonlyRole::Unsafe) { Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD) }
    assert_match "rolcreatedb", error.message
  end

  test "writes stay refused even if a session turns read-only off" do
    session.exec("SET default_transaction_read_only = off")

    assert_match "permission denied", refused("INSERT INTO organizations (name, slug, country_code, created_at, updated_at) " \
      "VALUES ('X', 'x', 'US', now(), now())").message
    assert_match "permission denied", refused("CREATE TABLE metabase_probe (id int)").message
  end

  test "only a SCRAM verifier reaches Postgres, never the password" do
    sql = []
    ActiveSupport::Notifications.subscribed(->(*, payload) { sql << payload[:sql] }, "sql.active_record") do
      Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD)
    end

    assert sql.any? { |statement| statement.match?(/ALTER ROLE .* PASSWORD 'SCRAM-SHA-256\$/) }, "the verifier was sent"
    assert sql.none? { |statement| statement.include?(PASSWORD) }, "the plaintext password was sent"
    stored = ActiveRecord::Base.connection.select_value("SELECT rolpassword FROM pg_authid WHERE rolname = #{ActiveRecord::Base.connection.quote(@name)}")
    assert stored.start_with?("SCRAM-SHA-256$"), "stored as a SCRAM verifier"
    assert_equal "1", session.exec("SELECT 1").getvalue(0, 0), "and the role still signs in with the password"
  end

  test "a table added later stays hidden, even after a rerun, until it's on the allow-list" do
    ActiveRecord::Base.connection.execute("CREATE TABLE metabase_later_table (id int)")
    assert_match "permission denied", refused("SELECT count(*) FROM metabase_later_table").message

    Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD)
    assert_match "permission denied", refused("SELECT count(*) FROM metabase_later_table").message, "no default privileges"
    assert_raises(ArgumentError) { Metabase::ReadonlyRole.apply!(name: @name, password: "short") }
  end

  test "every table is a decision: readable, or private" do
    tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata metabase_later_table]
    undecided = tables - Metabase::ReadonlyRole::READABLE_TABLES - Metabase::ReadonlyRole.private_tables(ActiveRecord::Base.connection)

    assert_empty undecided, "add each new table to READABLE_TABLES (and grant it in its migration) or to PRIVATE_TABLES"
    assert_empty Metabase::ReadonlyRole::READABLE_TABLES & Metabase::ReadonlyRole::PRIVATE_TABLES
    sensitive = %w[users sessions correction_reports data_deploys data_migrations solid_queue_jobs solid_cache_entries]
    assert_empty Metabase::ReadonlyRole::READABLE_TABLES & sensitive
  end

  test "it reads deal terms and the deploy's records stay hidden" do
    assert_equal "0", session.exec("SELECT count(*) FROM deal_terms WHERE id = 0").getvalue(0, 0)
    %w[data_deploys data_migrations].each do |table|
      assert_match "permission denied", refused("SELECT * FROM #{table}").message, table
    end
  end

  test "grant! adds one allow-listed table to an existing role, and refuses anything else" do
    connection = ActiveRecord::Base.connection
    connection.execute("REVOKE SELECT ON deal_terms FROM #{connection.quote_column_name(@name)}")
    assert_match "permission denied", refused("SELECT count(*) FROM deal_terms").message

    assert_equal %w[deal_terms], Metabase::ReadonlyRole.grant!(%w[deal_terms], name: @name)
    assert_equal "0", session.exec("SELECT count(*) FROM deal_terms WHERE id = 0").getvalue(0, 0)
    assert_raises(ArgumentError) { Metabase::ReadonlyRole.grant!(%w[correction_reports], name: @name) }
    assert_equal [], Metabase::ReadonlyRole.grant!(%w[deal_terms], name: "no_such_role_#{Process.pid}"), "no role, no grant"
  end

  test "a rerun takes away rights granted by hand in between" do
    connection = ActiveRecord::Base.connection
    role = connection.quote_column_name(@name)
    connection.execute("GRANT INSERT ON organizations TO #{role}")
    connection.execute("GRANT CREATE ON SCHEMA public TO #{role}")

    Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD)
    session.exec("SET default_transaction_read_only = off")

    assert_match "permission denied", refused("INSERT INTO organizations (name, slug, country_code, created_at, updated_at) " \
      "VALUES ('X', 'x', 'US', now(), now())").message
    assert_match "permission denied", refused("CREATE TABLE metabase_probe (id int)").message
  end

  test "a role that's a member of another role is refused" do
    other = "metabase_parent_test_#{Process.pid}"
    connection = ActiveRecord::Base.connection
    connection.execute("CREATE ROLE #{other}")
    connection.execute("GRANT #{other} TO #{connection.quote_column_name(@name)}")

    error = assert_raises(Metabase::ReadonlyRole::Unsafe) { Metabase::ReadonlyRole.apply!(name: @name, password: PASSWORD) }
    assert_match "is a member of #{other}", error.message
  ensure
    connection.execute("REVOKE #{other} FROM #{connection.quote_column_name(@name)}")
    connection.execute("DROP ROLE IF EXISTS #{other}")
  end
end
