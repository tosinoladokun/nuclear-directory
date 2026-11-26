require "test_helper"

# #950: on the 1st the month's draft is built and Data Quality is told it's
# ready; a failed build raises an alert instead.
class DatasetMonthlyDraftJobTest < ActiveSupport::TestCase
  REPO = "https://api.github.com/repos/tosinoladokun/nuclear-directory-data".freeze

  class Recorder
    attr_reader :raised, :resolved, :mailed
    def initialize = (@raised, @resolved, @mailed = [], [], [])
    def raise!(key, title:, body:, **) = @raised << [ key, title, body ]
    def resolve!(key, note: nil) = @resolved << key
    def notify(key:, title:, body:, state:, **) = @mailed << [ key, title, body, state ]
  end

  setup do
    company = Organization.create!(name: "Kairos Power", domain: "kairospower.com", verification_status: "verified", verified_by: "human:tosin")
    company.evidence.create!(source: sources(:press_release), quote: "Kairos Power develops reactors.", found_by: "human", confidence: 1)
    @recorder = Recorder.new
    # v2026.12 isn't tagged yet (Draft refuses a tagged version).
    stub_request(:get, "#{REPO}/git/ref/tags/v2026.12").to_return(status: 404, body: "{}")
    DatasetMonthlyDraftJob.alerts = @recorder
    DatasetMonthlyDraftJob.mailer = @recorder
  end

  teardown do
    DatasetMonthlyDraftJob.alerts = nil
    DatasetMonthlyDraftJob.mailer = nil
  end

  def stub_previous_release
    manifest = { "version" => "2026.11", "released_on" => "2026-10-27", "counts" => { "companies" => 3, "sources" => 1 }, "keys" => {} }
    stub_request(:get, "#{REPO}/releases/latest").to_return(status: 200, body: { tag_name: "v2026.11" }.to_json)
    stub_request(:get, "#{REPO}/contents/manifest.json?ref=v2026.11").to_return(status: 200, body: manifest.to_json)
    stub_request(:get, "#{REPO}/contents/CHANGELOG.md?ref=v2026.11").to_return(status: 200, body: "# Changelog\n")
  end

  test "builds the month's draft and emails that it's ready, with the counts and the change since last month" do
    stub_previous_release
    DatasetMonthlyDraftJob.perform_now("2026.12")

    assert DatasetRelease.find_by!(version: "2026.12").draft?
    key, title, body, state = @recorder.mailed.sole
    assert_equal [ "dataset-draft-ready", "Dataset v2026.12 is ready for Data Quality's check", :raised ], [ key, title, state ]
    assert_match "companies: 1 (-2 since 2026.11)", body
    assert_match "Admin > Dataset releases", body
    assert_equal [ "dataset-draft-failed" ], @recorder.resolved
  end

  test "a failed build raises an alert, emails no ready notice, and fails the job so it shows in the queue" do
    stub_request(:get, "#{REPO}/releases/latest").to_return(status: 500, body: { message: "boom" }.to_json)

    assert_raises(Dataset::Github::Error) { DatasetMonthlyDraftJob.perform_now("2026.12") }
    assert_equal [ "dataset-draft-failed", "The dataset draft v2026.12 couldn't be built" ], @recorder.raised.sole.first(2)
    assert_empty @recorder.mailed
  end

  test "a previous release with no manifest.json is a failed build, not a refusal (Copilot)" do
    stub_request(:get, "#{REPO}/releases/latest").to_return(status: 200, body: { tag_name: "v2026.11" }.to_json)
    stub_request(:get, "#{REPO}/contents/manifest.json?ref=v2026.11").to_return(status: 404, body: { message: "Not Found" }.to_json)

    assert_raises(Dataset::Draft::MissingInput) { DatasetMonthlyDraftJob.perform_now("2026.12") }
    key, title, body = @recorder.raised.sole
    assert_equal [ "dataset-draft-failed", "The dataset draft v2026.12 couldn't be built" ], [ key, title ]
    assert_match "v2026.11 has no manifest.json", body
    assert_empty @recorder.mailed
  end

  test "it runs in one concurrency group with Rebuild and Publish, so a build never runs while Publish reads the draft (Copilot)" do
    groups = [ DatasetMonthlyDraftJob, DatasetBuildDraftJob, DatasetPublishJob ].map { |job| [ job.concurrency_key, job.concurrency_group ] }.uniq
    assert_equal [ [ "dataset_release", "dataset_release" ] ], groups
  end

  test "Rebuild clears the failed-build alert once it works (Copilot)" do
    stub_previous_release
    DatasetBuildDraftJob.alerts = @recorder
    DatasetBuildDraftJob.perform_now("2026.12")

    assert_equal [ "dataset-draft-failed" ], @recorder.resolved
  ensure
    DatasetBuildDraftJob.alerts = nil
  end

  test "a published month isn't rebuilt, and nobody is emailed" do
    DatasetRelease.create!(version: "2026.12", status: "published")
    DatasetMonthlyDraftJob.perform_now("2026.12")

    assert_empty @recorder.mailed
    assert_empty @recorder.raised
  end
end
