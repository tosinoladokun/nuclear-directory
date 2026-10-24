# Tests for ci_scope.rb. Run by CI (blueprint job):
#   ruby .github/scripts/ci_scope_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "ci_scope"

class CiScopeTest < Minitest::Test
  ALL = { test: true, system: true, lighthouse: true }.freeze
  NOTHING = { test: false, system: false, lighthouse: false }.freeze
  UNIT_ONLY = { test: true, system: false, lighthouse: false }.freeze

  def scope(*paths)
    CiScope.scope(paths)
  end

  def test_docs_only_skips_everything
    assert_equal NOTHING,
      scope("README.md", "DESIGN.md", "backend/app/data_quality/README.md", "planning/prd.md",
        "docs/snapshot-api.md")
  end

  def test_render_yaml_or_github_only_runs_unit_tests
    assert_equal UNIT_ONLY, scope("render.yaml")
    assert_equal UNIT_ONLY, scope(".github/scripts/check_blueprint.rb", ".github/workflows/preview.yml")
    assert_equal UNIT_ONLY, scope("backup/backup.sh", "docker-compose.yml", "README.md")
  end

  def test_a_change_to_ci_itself_runs_everything
    assert_equal ALL, scope(".github/workflows/ci.yml")
    assert_equal ALL, scope(".github/scripts/ci_scope.rb")
    assert_equal ALL, scope(".github/scripts/ci_scope_test.rb")
  end

  def test_data_only_changes_run_unit_tests_only
    %w[
      backend/db/seeds/organizations/kairos-power.yml backend/db/seeds/facilities.yml
      backend/db/data/20261021200000_hitachi_no_reactor_designer.rb
      backend/app/data_quality/plugins/nrc_reactor_list.rb backend/app/data_quality/fetcher.rb
      backend/test/data_quality/plugins/nrc_reactor_list_test.rb backend/test/seeds_test.rb
      backend/test/fixtures/files/nrc/list.html
    ].each do |path|
      assert_equal UNIT_ONLY, scope(path), path
    end
    assert_equal UNIT_ONLY, scope("backend/db/seeds/facilities.yml", "backend/app/data_quality/README.md", "docs/DATA.md")
  end

  def test_unit_test_files_run_unit_tests_only
    assert_equal UNIT_ONLY, scope("backend/test/models/organization_test.rb", "backend/test/helpers/directory_helper_test.rb")
  end

  def test_public_page_code_runs_everything
    %w[
      backend/app/views/companies/show.html.erb backend/app/views/layouts/application.html.erb
      backend/app/assets/tailwind/design_system/components.css
      backend/app/javascript/controllers/search_controller.js backend/app/helpers/directory_helper.rb
      backend/config/routes.rb backend/app/controllers/home_controller.rb
      backend/app/controllers/directory_controller.rb backend/app/controllers/companies_controller.rb
      backend/app/controllers/application_controller.rb
    ].each do |path|
      assert_equal ALL, scope(path), path
    end
  end

  def test_the_admin_and_browser_tests_run_the_browser_tests_without_lighthouse
    %w[
      backend/app/views/admin/today/show.html.erb backend/app/controllers/admin/today_controller.rb
      backend/app/controllers/api/snapshots_controller.rb backend/test/system/home_cards_test.rb
      backend/test/application_system_test_case.rb
    ].each do |path|
      assert_equal({ test: true, system: true, lighthouse: false }, scope(path), path)
    end
  end

  def test_other_app_changes_run_everything
    %w[
      backend/db/migrate/20261011030000_add_decision.rb backend/lib/analytics.rb backend/public/robots.txt
      backend/Gemfile backend/Gemfile.lock backend/Dockerfile backend/app/models/organization.rb
      backend/config/environments/production.rb backend/lighthouserc.json
    ].each do |path|
      assert_equal ALL, scope(path), path
    end
  end

  def test_one_page_file_among_data_runs_everything
    assert_equal ALL, scope("backend/db/seeds/facilities.yml", "backend/app/views/home/show.html.erb")
  end

  def test_one_app_file_among_docs_runs_everything
    assert_equal ALL, scope("README.md", "backend/app/models/organization.rb")
  end

  def test_unknown_or_empty_runs_everything
    assert_equal ALL, scope("some/new/thing.txt")
    assert_equal ALL, scope
    assert_equal ALL, scope("", "  ")
  end

  def test_the_command_line_writes_github_outputs
    Dir.mktmpdir do |dir|
      output_file = File.join(dir, "github_output")
      stdout, stderr, status = Open3.capture3({ "GITHUB_OUTPUT" => output_file }, "ruby",
        File.expand_path("ci_scope.rb", __dir__), stdin_data: "README.md\nrender.yaml\n")
      assert status.success?, stderr
      assert_equal "test=true\nsystem=false\nlighthouse=false\n", File.read(output_file)
      assert_empty stdout
    end
  end
end
