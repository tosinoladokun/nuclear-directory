require "test_helper"

# #950: the monthly draft, built from the data and the previous release's
# manifest on GitHub (stubbed), stored on the row with no files left on disk.
class Dataset::DraftTest < ActiveSupport::TestCase
  REPO = "https://api.github.com/repos/tosinoladokun/nuclear-directory-data".freeze
  BY = "human:tosin"

  setup do
    company = Organization.create!(name: "Kairos Power", domain: "kairospower.com", verification_status: "verified", verified_by: BY)
    company.evidence.create!(source: sources(:press_release), quote: "Kairos Power develops reactors.", found_by: "human", confidence: 1)
    manifest = { "version" => "2026.11", "released_on" => "2026-10-27", "counts" => { "companies" => 1, "sources" => 1 },
      "keys" => { "companies" => [ "old-co" ] } }
    stub_request(:get, "#{REPO}/releases/latest").to_return(status: 200, body: { tag_name: "v2026.11" }.to_json)
    stub_request(:get, "#{REPO}/git/ref/tags/v2026.12").to_return(status: 404, body: "{}")
    stub_request(:get, "#{REPO}/contents/manifest.json?ref=v2026.11").to_return(status: 200, body: manifest.to_json)
    stub_request(:get, "#{REPO}/contents/CHANGELOG.md?ref=v2026.11").to_return(status: 200, body: "# Changelog\n\n## 2026.11 (2026-10-27)\n\nFirst release.\n")
    @github = Dataset::Github.new(token: nil)
  end

  def build(tables: Dataset::Export::TABLES.keys) = Dataset::Draft.build!(version: "2026.12", github: @github, tables:)

  test "builds the draft: counts, the change since the last release, the changelog and every file, gzipped" do
    release = build

    assert_equal [ "draft", "2026.11", { "companies" => 1, "sources" => 1 } ], [ release.status, release.previous_version, release.previous_counts ]
    assert_equal 1, release.counts["companies"]
    assert_match "Compared with 2026.11.", release.changelog
    assert_match "- New companies: kairos-power", release.changelog
    assert_match "## 2026.11 (2026-10-27)", release.changelog, "the history is kept"
    paths = release.files.map(&:path)
    Dataset::Export::TABLES.each_key { |table| assert_includes paths, "#{table}.csv" }
    assert_includes paths, ".zenodo.json"
    readme = release.files.find_by!(path: "README.md")
    assert_equal DatasetReleaseFile.git_sha(readme.content), readme.git_sha
    assert_match "Version 2026.12", readme.content
  end

  test "the five-table setting leaves the two tables' files out, and the changelog says they're held back" do
    release = build(tables: Dataset::Export::CORE_TABLES)

    assert_equal Dataset::Export::CORE_TABLES.sort, release.tables_included.sort
    assert_empty release.files.map(&:path).grep(/\A(deal_terms|licensing_stages)\./)
    assert_equal 10, release.files.map(&:path).grep(Dataset::Publisher::TABLE_FILE).size, "five tables, each as CSV and JSON"
    assert_match "Held back from this release: `deal_terms` and `licensing_stages`.", release.changelog
  end

  test "the setting comes from DATASET_TABLES: the five core tables unless it names the other two (DQ)" do
    assert_equal Dataset::Export::CORE_TABLES, DatasetRelease.tables_setting
    ENV["DATASET_TABLES"] = "deal_terms"
    assert_equal %w[companies facilities relationships deal_terms sources evidence].sort, DatasetRelease.tables_setting.sort
    ENV["DATASET_TABLES"] = "companies, evidence"
    assert_equal Dataset::Export::CORE_TABLES, DatasetRelease.tables_setting
    ENV["DATASET_TABLES"] = "deal_terms licensing_stages"
    assert_equal Dataset::Export::TABLES.keys, DatasetRelease.tables_setting
  ensure
    ENV.delete("DATASET_TABLES")
  end

  test "a rebuild replaces the draft's files" do
    first = build
    old_ids = first.files.pluck(:id)

    again = build

    assert_equal first.id, again.id
    assert_empty DatasetReleaseFile.where(id: old_ids)
    assert_equal old_ids.size, again.files.count
  end

  test "never rebuilds a published release, or one whose publishing made a commit" do
    release = build
    release.update!(commit_sha: "abc1234", status: "failed")
    assert_raises(Dataset::Draft::Refused) { build }
    release.update!(status: "published")
    error = assert_raises(Dataset::Draft::Refused) { build }
    assert_match "published", error.message
    assert_equal "abc1234", release.reload.commit_sha
  end

  test "refuses a version already tagged on GitHub, released or not, latest or not (Copilot)" do
    stub_request(:get, "#{REPO}/git/ref/tags/v2026.12").to_return(status: 200, body: { object: { type: "commit", sha: "abc" } }.to_json)
    error = assert_raises(Dataset::Draft::Refused) { build }
    assert_equal "v2026.12 is already tagged on GitHub", error.message
    assert_not DatasetRelease.exists?(version: "2026.12")
  end

  test "stores the tables it exported, the core ones included (Copilot)" do
    release = build(tables: %w[deal_terms])
    assert_equal %w[companies facilities relationships deal_terms sources evidence].sort, release.tables_included.sort
  end
end
