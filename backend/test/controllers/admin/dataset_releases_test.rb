require "test_helper"

# #950: the Dataset releases page: the draft, Rebuild, Dry run and Publish.
class Admin::DatasetReleasesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    sign_in_as users(:admin)
    @release = DatasetRelease.create!(version: "2026.12", counts: { "companies" => 160, "sources" => 430 },
      previous_version: "2026.11", previous_counts: { "companies" => 157, "sources" => 430 }, tables_included: Dataset::Export::TABLES.keys,
      unknown_publishers: [ "example.org" ], changelog: "# Changelog\n\n## 2026.12", built_at: Time.current)
    @release.files.create!(DatasetReleaseFile.build_from("README.md", "# Readme").attributes.slice("path", "content_gz", "bytes", "git_sha"))
  end

  teardown { ENV.delete("DATASET_GITHUB_TOKEN") }

  test "shows the draft's counts, the change since the last release, the changelog and unknown publishers" do
    get admin_dataset_releases_path

    assert_response :success
    assert_select "#dataset-counts tr", text: /companies\s*160\s*\+3/
    assert_select "#dataset-counts tr", text: /sources\s*430\s*0/
    assert_equal %w[companies sources], css_select("#dataset-counts tbody th").map(&:text), "in the tables' order"
    assert_select "#dataset-changelog", /## 2026.12/
    assert_select "#dataset-unknown-publishers li", "example.org"
  end

  test "without the token the page says publishing isn't set up and Publish is disabled" do
    get admin_dataset_releases_path

    assert_select "#dataset-not-set-up", /isn't set up/
    assert_select "#dataset-publish[disabled]"
    assert_no_enqueued_jobs(only: DatasetPublishJob) { post admin_dataset_release_publish_path(@release) }
    assert_equal "Publishing isn't set up yet.", flash[:alert]
  end

  test "with the token, Publish is enabled and queues the job, and the token never shows on the page" do
    ENV["DATASET_GITHUB_TOKEN"] = "github_pat_secret"
    get admin_dataset_releases_path

    assert_select "#dataset-not-set-up", false
    assert_select "#dataset-publish:not([disabled])"
    assert_not_includes response.body, "github_pat_secret"
    assert_enqueued_with(job: DatasetPublishJob, args: [ @release.id ]) { post admin_dataset_release_publish_path(@release) }
  end

  test "a published release can't be published or rebuilt again" do
    ENV["DATASET_GITHUB_TOKEN"] = "github_pat_secret"
    @release.update!(status: "published", release_url: "https://github.com/x/releases/tag/v2026.12", published_at: Time.current)

    assert_no_enqueued_jobs { post admin_dataset_release_publish_path(@release) }
    assert_no_enqueued_jobs { post admin_dataset_releases_build_path, params: { version: "2026.12" } }
    get admin_dataset_releases_path
    assert_select "#dataset-published-list tr", text: /2026.12/
  end

  test "Rebuild queues the build for that version" do
    assert_enqueued_with(job: DatasetBuildDraftJob, args: [ "2026.12" ]) { post admin_dataset_releases_build_path, params: { version: "2026.12" } }
    assert_no_enqueued_jobs { post admin_dataset_releases_build_path, params: { version: "../x" } }
  end

  test "held-back tables are named on the page" do
    @release.update!(tables_included: Dataset::Export::CORE_TABLES)
    get admin_dataset_releases_path
    assert_select "#dataset-held-back", /deal_terms and licensing_stages/
  end
end
