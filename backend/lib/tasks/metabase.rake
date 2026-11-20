require "io/console"

namespace :metabase do
  desc "Create or update the read-only role local Metabase uses (#111). Prompts for its password; safe to rerun"
  task create_readonly_role: :environment do
    unless Metabase::ReadonlyRole.can_create_roles?
      abort "This database user can't create roles. Run this as the database owner (Render shell on the web service)."
    end

    # Typed at a prompt only, never on the command line, so it isn't in the
    # shell's history.
    console = IO.console or abort "Run this in a terminal (Render: web service → Shell), so it can ask for the password."
    password = console.getpass("Password for #{Metabase::ReadonlyRole::NAME} (paste from your password manager): ")
    abort "The two passwords don't match; nothing was changed." unless console.getpass("Same password again: ") == password

    Metabase::ReadonlyRole.apply!(password:)
    database = ActiveRecord::Base.connection.current_database
    puts "#{Metabase::ReadonlyRole::NAME} is ready: read-only on #{database}, no access to " \
      "#{Metabase::ReadonlyRole::PRIVATE_TABLES.join(' or ')}."
  end
end

# schema.rb keeps no views, so a database loaded from it (db:prepare on a
# fresh database, db:schema:load) gets them here, as migrating would have.
Rake::Task["db:schema:load"].enhance { Metabase::ReadonlyRole.create_views! } if Rake::Task.task_defined?("db:schema:load")
