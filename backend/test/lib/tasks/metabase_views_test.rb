require "test_helper"
require "rake"

# A fresh database loaded from schema.rb (db:prepare) gets metabase_leads too.
class MetabaseViewsTaskTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "loading the schema creates the role's views" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:schema:load")
    connection = ActiveRecord::Base.connection
    connection.execute("DROP VIEW IF EXISTS metabase_leads")
    Rake::Task["db:schema:load"].actions.last.call(Rake::Task["db:schema:load"])
    assert_includes connection.views, "metabase_leads"
  ensure
    ActiveRecord::Base.connection.execute("DROP VIEW IF EXISTS metabase_leads")
  end
end
