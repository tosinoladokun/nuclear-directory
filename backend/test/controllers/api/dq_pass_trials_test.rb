require "test_helper"

# #998: Data Quality's dry-run trial of the pass's research, before its switch-on.
class Api::DqPassTrialsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  TOKEN = "dq-token"

  setup { ENV["DQ_AGENT_TOKEN_DIGEST"] = Digest::SHA256.hexdigest(TOKEN) }
  teardown do
    ENV.delete("DQ_AGENT_TOKEN_DIGEST")
    DqPassTrialJob.research = nil
  end

  def auth = { "Authorization" => "Bearer #{TOKEN}" }

  test "it needs the token and 1 to 25 company ids" do
    post api_dq_pass_trials_path, params: { organization_ids: [ 1 ] }, as: :json
    assert_response :unauthorized
    post api_dq_pass_trials_path, params: { organization_ids: [] }, headers: auth, as: :json
    assert_response :unprocessable_content
    post api_dq_pass_trials_path, params: { organization_ids: (1..26).to_a }, headers: auth, as: :json
    assert_response :unprocessable_content
  end

  test "a trial runs as a dry run, even with the switch off, and its answers are read back; nothing is proposed" do
    org = Organization.create!(name: "Acme Fission", verification_status: "pending")
    fake = Struct.new(:run) do
      def research(org) = { outcome: "would_propose", answer: { "model" => "vendor/extract", "website" => "https://acme.example", "role" => "components", "sure" => true },
        proposed: [ { "action" => "propose_role", "role" => "components" } ], errors: [] }
    end
    made = []
    DqPassTrialJob.research = ->(**opts) { made << opts; fake.new }

    assert_not DqPass.on?
    post api_dq_pass_trials_path, params: { organization_ids: [ org.id ] }, headers: auth, as: :json
    assert_response :accepted
    token = response.parsed_body["id"]

    # Queued: no run yet, so the hourly sweep has nothing to fail (Copilot).
    assert_equal 0, CrawlRun.where(source_kind: DqPass::TRIAL_KIND).count
    get api_dq_pass_trial_path(token), headers: auth
    assert_equal "queued", response.parsed_body["status"]

    travel 2.hours do
      perform_enqueued_jobs
      run = CrawlRun.find_by!(source_kind: DqPass::TRIAL_KIND)
      assert_in_delta Time.current, run.started_at, 5, "its spend counts on the day it ran (Copilot)"
    end
    assert_equal [ { dry_run: true } ], made

    get api_dq_pass_trial_path(token), headers: auth
    body = response.parsed_body
    assert_equal "succeeded", body["status"]
    assert_equal [ "Acme Fission", "would_propose", "components" ], body["results"].first.values_at("name", "outcome", "role")
    assert_equal [ { "action" => "propose_role", "role" => "components" } ], body["results"].first["would_propose"]
    assert_equal 0, Candidate.count

    get api_dq_pass_trial_path("not-a-token"), headers: auth
    assert_response :not_found
  end

  test "the trial runs holding its pipeline lock; busy, it tries again later (Copilot)" do
    held = nil
    DqPassTrialJob.research = ->(**) { Struct.new(:run) { define_method(:research) { |_org| held = :ran; { outcome: "nothing", answer: {}, proposed: [] } } }.new }
    real = DataQuality::Pipeline.method(:with_lock)
    kinds = []
    DataQuality::Pipeline.define_singleton_method(:with_lock) { |kind, &block| kinds << kind; block.call }
    DqPassTrialJob.perform_now(SecureRandom.uuid, [ Organization.create!(name: "Lock Co", verification_status: "pending").id ])
    assert_equal [ DqPass::TRIAL_KIND ], kinds
    assert_equal :ran, held
  ensure
    DataQuality::Pipeline.define_singleton_method(:with_lock, real)
  end

  test "the trial's spend counts in the daily cap" do
    CrawlRun.create!(source_kind: DqPass::TRIAL_KIND, stage: "verify", stats: { "llm" => { "cost" => 1.0 } })
    assert_not DqPass.budget_left?
  end
end
