require "test_helper"

# #950: publishing a dataset release through the GitHub API, stubbed here.
class Dataset::PublisherTest < ActiveSupport::TestCase
  REPO = "https://api.github.com/repos/tosinoladokun/nuclear-directory-data".freeze
  TOKEN = "github_pat_test_never_shown".freeze

  setup do
    @release = DatasetRelease.create!(version: "2026.12", counts: { "companies" => 160, "sources" => 430 }, previous_version: "2026.11",
      tables_included: Dataset::Export::CORE_TABLES, built_at: Time.current, changelog: "# Changelog")
    @readme = "# Readme\n"
    { "README.md" => @readme, "companies.csv" => "slug\nkairos-power\n", "manifest.json" => "{}" }.each do |path, content|
      @release.files.create!(DatasetReleaseFile.build_from(path, content).attributes.slice("path", "content_gz", "bytes", "git_sha"))
    end
    @github = Dataset::Github.new(token: TOKEN)
  end

  def publisher = Dataset::Publisher.new(@release.reload, github: @github)
  def json(body, status = 200) = { status:, body: JSON.generate(body), headers: { "Content-Type" => "application/json" } }

  # The repo as v2026.11 left it: README unchanged, companies.csv older,
  # no manifest.json yet, and a held-back table's file to delete.
  def stub_repo(tag: nil)
    stub_request(:get, "#{REPO}/git/ref/tags/v2026.12").to_return(tag ? json("object" => { "type" => "tag", "sha" => "tagobj" }) : json({}, 404))
    stub_request(:get, "#{REPO}/git/tags/tagobj").to_return(json("object" => { "sha" => tag })) if tag
    stub_request(:get, "#{REPO}/git/ref/heads/main").to_return(json("object" => { "sha" => "head1" }))
    stub_request(:get, "#{REPO}/git/commits/head1").to_return(json("tree" => { "sha" => "tree1" }))
    stub_request(:get, "#{REPO}/git/trees/tree1?recursive=1").to_return(json("tree" => [
      { "path" => "README.md", "type" => "blob", "sha" => DatasetReleaseFile.git_sha(@readme) },
      { "path" => "companies.csv", "type" => "blob", "sha" => "old" },
      { "path" => "deal_terms.csv", "type" => "blob", "sha" => "old2" },
      { "path" => "notes.txt", "type" => "blob", "sha" => "keep" }
    ]))
  end

  def stub_writes
    @blobs = stub_request(:post, "#{REPO}/git/blobs").to_return(json("sha" => "blob1"), json("sha" => "blob2"))
    @tree = stub_request(:post, "#{REPO}/git/trees").to_return(json("sha" => "tree2"))
    @commit = stub_request(:post, "#{REPO}/git/commits").with(body: hash_including("message" => "Release 2026.12", "tree" => "tree2", "parents" => [ "head1" ]))
      .to_return(json("sha" => "commit2"))
    @compare = stub_request(:get, "#{REPO}/compare/head1...commit2").to_return(json("status" => "ahead"))
    @move = stub_request(:patch, "#{REPO}/git/refs/heads/main").with(body: { sha: "commit2", force: false }.to_json).to_return(json({}))
    @tag = stub_request(:post, "#{REPO}/git/tags").with(body: hash_including("tag" => "v2026.12", "object" => "commit2", "type" => "commit"))
      .to_return(json("sha" => "tagobj"))
    @ref = stub_request(:post, "#{REPO}/git/refs").with(body: { ref: "refs/tags/v2026.12", sha: "tagobj" }.to_json).to_return(json({}))
    stub_request(:get, "#{REPO}/releases/tags/v2026.12").to_return(json({}, 404))
    @made = stub_request(:post, "#{REPO}/releases").with(body: hash_including("tag_name" => "v2026.12", "name" => "2026.12"))
      .to_return(json("html_url" => "https://github.com/tosinoladokun/nuclear-directory-data/releases/tag/v2026.12"))
  end

  test "publishes: blobs for the changed files, a tree on main, the commit, main moved, the tag and the release" do
    stub_repo
    stub_writes

    publisher.publish!

    @release.reload
    assert_equal [ "published", "commit2", "https://github.com/tosinoladokun/nuclear-directory-data/releases/tag/v2026.12" ],
      [ @release.status, @release.commit_sha, @release.release_url ]
    assert_requested @blobs, times: 2, headers: { "Authorization" => "Bearer #{TOKEN}" }
    assert_requested(:post, "#{REPO}/git/trees") do |request|
      body = JSON.parse(request.body)
      entries = body["tree"].to_h { |entry| [ entry["path"], entry["sha"] ] }
      body["base_tree"] == "tree1" && entries == { "companies.csv" => "blob1", "manifest.json" => "blob2", "deal_terms.csv" => nil }
    end
    [ @commit, @move, @tag, @ref, @made ].each { |stub| assert_requested stub, times: 1 }
    assert_requested(:post, "#{REPO}/releases") { |request| JSON.parse(request.body)["body"].include?("160 companies and 430 sources, each table") }
  end

  test "a retry after a failure partway through picks up at the step that failed" do
    stub_repo
    stub_writes
    stub_request(:post, "#{REPO}/git/refs").to_return(json({ "message" => "Server Error" }, 500)).then.to_return(json({}))

    error = assert_raises(Dataset::Github::Error) { publisher.publish! }
    assert_match "500", error.message
    @release.reload
    assert_equal [ "failed", "commit2" ], [ @release.status, @release.commit_sha ], "the commit is kept for the retry"
    assert_match "POST /git/refs", @release.error
    assert_no_match TOKEN, @release.error

    stub_request(:get, "#{REPO}/git/ref/heads/main").to_return(json("object" => { "sha" => "commit2" }))
    publisher.publish!

    assert_equal "published", @release.reload.status
    assert_requested @commit, times: 1 # no second commit
    assert_requested @blobs, times: 2 # no blobs uploaded again
    assert_requested @move, times: 1 # main was already there
    assert_requested @made, times: 1
  end

  test "a retry after the tag was made only creates the release" do
    @release.update!(commit_sha: "commit2", status: "failed")
    stub_repo(tag: "commit2")
    stub_writes

    publisher.publish!

    assert_equal "published", @release.reload.status
    assert_not_requested @commit
    assert_not_requested @ref
    assert_requested @made, times: 1
  end

  test "refuses when the tag already exists at another commit, and writes nothing" do
    stub_repo(tag: "someone-elses")
    stub_writes

    error = assert_raises(Dataset::Publisher::Refused) { publisher.publish! }

    assert_match "v2026.12 already exists on GitHub at commit someone", error.message
    assert_equal "failed", @release.reload.status
    [ @blobs, @commit, @move, @ref, @made ].each { |stub| assert_not_requested stub }
  end

  test "without the token it refuses before calling GitHub and leaves the draft as it was" do
    @github = Dataset::Github.new(token: nil)

    error = assert_raises(Dataset::Publisher::Refused) { publisher.publish! }

    assert_match "publishing isn't set up", error.message
    assert_equal [ "draft", nil ], [ @release.reload.status, @release.error ]
    assert_not_requested :any, /api.github.com/
  end

  test "main having moved on drops the unpushed commit, so the next run commits on top" do
    stub_repo
    stub_writes
    stub_request(:patch, "#{REPO}/git/refs/heads/main").to_return(json({ "message" => "Update is not a fast forward" }, 422))

    assert_raises(Dataset::Publisher::Refused) { publisher.publish! }

    assert_equal [ "failed", nil ], [ @release.reload.status, @release.commit_sha ]
    assert_not_requested @ref
  end

  test "a draft rebuilt after Publish was pressed isn't published" do
    pressed = Dataset::Publisher.stamp(@release.built_at)
    @release.update!(built_at: 1.minute.from_now)

    assert_raises(Dataset::Publisher::Refused) { publisher.publish!(built_at: pressed) }
    assert_not_requested :any, /api.github.com/
  end

  test "the job logs a second Publish of a published release, without an alert" do
    @release.update!(status: "published")
    assert_nothing_raised { DatasetPublishJob.perform_now(@release.id) }
    assert_equal "published", @release.reload.status
  end

  test "main having diverged from the saved commit drops it without trying to move main" do
    @release.update!(commit_sha: "commit2", status: "failed")
    stub_repo
    stub_writes
    stub_request(:get, "#{REPO}/compare/head1...commit2").to_return(json("status" => "diverged"))

    assert_raises(Dataset::Publisher::Refused) { publisher.publish! }

    assert_nil @release.reload.commit_sha
    assert_not_requested @move
    assert_not_requested @ref
  end

  test "a saved commit GitHub no longer has (404 on compare) is dropped, never stuck; the dry run says so (Infra)" do
    @release.update!(commit_sha: "commit2", status: "failed")
    stub_repo
    stub_writes
    stub_request(:get, "#{REPO}/compare/head1...commit2").to_return(json({ "message" => "Not Found" }, 404))

    assert_match "main moved on since commit commit2", publisher.dry_run["blocked"]
    assert_raises(Dataset::Publisher::Refused) { publisher.publish! }

    assert_equal [ "failed", nil ], [ @release.reload.status, @release.commit_sha ]
    assert @release.rebuildable?, "Rebuild works again"
    assert_not_requested @move
  end

  test "main that already has the saved commit isn't moved; the tag and release follow" do
    @release.update!(commit_sha: "commit2", status: "failed")
    stub_repo
    stub_writes
    stub_request(:get, "#{REPO}/compare/head1...commit2").to_return(json("status" => "behind"))

    publisher.publish!

    assert_equal "published", @release.reload.status
    assert_not_requested @move
    assert_not_requested @commit
    assert_requested @ref, times: 1
  end

  test "a dry run after a partial publish shows only the steps left (Copilot)" do
    @release.update!(commit_sha: "commit2", status: "failed")
    stub_repo
    stub_writes

    run = publisher.dry_run

    assert_equal [ %w[move_main tag release], nil, [] ], run.values_at("steps", "blocked", "changed")
    assert_not_requested :get, "#{REPO}/git/trees/tree1?recursive=1"
    [ @blobs, @commit, @move, @ref, @made ].each { |stub| assert_not_requested stub }
  end

  test "a dry run with the tag already made shows only the release; with main diverged it says publishing would stop" do
    @release.update!(commit_sha: "commit2", status: "failed")
    stub_repo(tag: "commit2")
    stub_writes
    assert_equal %w[release], publisher.dry_run["steps"]

    stub_repo
    stub_request(:get, "#{REPO}/compare/head1...commit2").to_return(json("status" => "diverged"))
    run = publisher.dry_run
    assert_equal [], run["steps"]
    assert_match "main moved on since commit commit2", run["blocked"]
  end

  test "a published release is never published again" do
    @release.update!(status: "published")
    assert_raises(Dataset::Publisher::AlreadyPublished) { publisher.publish! }
    assert_not_requested :any, /api.github.com/
  end

  test "a dry run reads the repo, says what would change and writes nothing to GitHub" do
    stub_repo
    stub_writes

    run = publisher.dry_run

    assert_equal [ [ "manifest.json" ], [ "companies.csv" ], [ "deal_terms.csv" ], 1, nil ], run.values_at("added", "changed", "removed", "unchanged", "blocked")
    assert_equal Dataset::Publisher::STEPS, run["steps"]
    assert_equal [ "Release 2026.12", "v2026.12", "2026.12" ], run.values_at("commit_message", "tag", "release_name")
    assert_equal run, @release.reload.dry_run
    assert_equal "draft", @release.status
    [ @blobs, @tree, @commit, @move, @tag, @ref, @made ].each { |stub| assert_not_requested stub }
  end

  test "a dry run without the token still runs, and says publishing would stop" do
    @github = Dataset::Github.new(token: nil)
    stub_repo

    assert_equal "DATASET_GITHUB_TOKEN is missing", publisher.dry_run["blocked"]
    assert_not_requested(:get, "#{REPO}/git/ref/heads/main", headers: { "Authorization" => /.*/ })
  end
end
