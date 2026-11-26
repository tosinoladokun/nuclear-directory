require "test_helper"

# #950: the hourly watch saves each published release's Zenodo DOI, and says
# so when the DOI doesn't come or the month's release isn't out by the 7th.
class DatasetReleaseWatchJobTest < ActiveSupport::TestCase
  class Recorder
    attr_reader :raised, :resolved
    def initialize = (@raised, @resolved = [], [])
    def raise!(key, title:, body:, **) = @raised << [ key, title, body ]
    def resolve!(key, note: nil) = @resolved << key
  end

  # Stands in for Dataset::Zenodo: { version => doi }, or an error.
  class FakeZenodo
    def initialize(dois = {}, error: nil) = (@dois, @error = dois, error)

    def version_doi(version)
      raise Dataset::Zenodo::Error, @error if @error

      @dois[version]
    end
  end

  setup do
    @alerts = Recorder.new
    DatasetReleaseWatchJob.alerts = @alerts
    DatasetReleaseWatchJob.zenodo = FakeZenodo.new
  end

  teardown do
    DatasetReleaseWatchJob.alerts = nil
    DatasetReleaseWatchJob.zenodo = nil
  end

  def release(version, **attrs) = DatasetRelease.create!({ version:, status: "draft" }.merge(attrs))
  def published(version, at:, **attrs) = release(version, status: "published", published_at: at, release_url: "https://github.com/x/releases/tag/v#{version}", **attrs)
  def run_job(now) = DatasetReleaseWatchJob.perform_now(now:)

  test "saves the version DOI once Zenodo has it, and resolves the DOI alert" do
    now = Time.zone.local(2026, 12, 3, 12)
    row = published("2026.12", at: now - 30.minutes)
    DatasetReleaseWatchJob.zenodo = FakeZenodo.new({ "2026.12" => "10.5281/zenodo.24000001" })

    run_job(now)

    assert_equal "10.5281/zenodo.24000001", row.reload.version_doi
    assert_includes @alerts.resolved, DatasetReleaseWatchJob::NO_DOI
    assert_includes @alerts.resolved, DatasetReleaseWatchJob::LATE, "December's release is out"
    assert_empty @alerts.raised
  end

  test "waits quietly for the DOI, then alerts once it's overdue" do
    now = Time.zone.local(2026, 12, 3, 12)
    published("2026.12", at: now - 1.hour)
    run_job(now)
    assert_empty @alerts.raised, "Zenodo gets two hours"

    run_job(now + 2.hours)
    key, title, body = @alerts.raised.sole
    assert_equal [ DatasetReleaseWatchJob::NO_DOI, "No Zenodo DOI for dataset v2026.12" ], [ key, title ]
    assert_includes body, "releases/tag/v2026.12"
  end

  test "a Zenodo error counts as not found yet, never as a crash" do
    now = Time.zone.local(2026, 12, 3, 12)
    published("2026.12", at: now - 3.hours)
    DatasetReleaseWatchJob.zenodo = FakeZenodo.new(error: "zenodo.org didn't answer (OpenTimeout)")

    assert_nothing_raised { run_job(now) }
    assert_equal [ DatasetReleaseWatchJob::NO_DOI ], @alerts.raised.map(&:first)
  end

  test "before the 7th nothing is late; from the 7th an unpublished month raises one alert saying where it's stuck" do
    run_job(Time.zone.local(2026, 12, 6, 12))
    assert_empty @alerts.raised

    run_job(Time.zone.local(2026, 12, 7, 12))
    key, title, body = @alerts.raised.sole
    assert_equal [ DatasetReleaseWatchJob::LATE, "Dataset v2026.12 isn't published yet" ], [ key, title ]
    assert_match "No draft has been built", body

    @alerts.raised.clear
    release("2026.12", status: "failed", error: "GitHub said 422 to PATCH /git/refs/heads/main")
    run_job(Time.zone.local(2026, 12, 8, 12))
    assert_match "Publishing failed: GitHub said 422", @alerts.raised.sole.last
  end

  test "a published release with its DOI resolves both alerts and calls Zenodo for nothing" do
    published("2026.12", at: Time.zone.local(2026, 12, 2), version_doi: "10.5281/zenodo.24000001")
    DatasetReleaseWatchJob.zenodo = FakeZenodo.new(error: "should not be called")

    run_job(Time.zone.local(2026, 12, 9, 12))

    assert_equal [ DatasetReleaseWatchJob::NO_DOI, DatasetReleaseWatchJob::LATE ], @alerts.resolved
    assert_empty @alerts.raised
  end
end
