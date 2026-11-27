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
    perform_enqueued_jobs { post api_dq_pass_trials_path, params: { organization_ids: [ org.id ] }, headers: auth, as: :json }
    assert_response :accepted
    id = response.parsed_body["id"]
    assert_equal [ { dry_run: true } ], made

    get api_dq_pass_trial_path(id), headers: auth
    body = response.parsed_body
    assert_equal "succeeded", body["status"]
    assert_equal [ "Acme Fission", "would_propose", "components" ], body["results"].first.values_at("name", "outcome", "role")
    assert_equal [ { "action" => "propose_role", "role" => "components" } ], body["results"].first["would_propose"]
    assert_equal 0, Candidate.count
  end

  test "the trial's spend counts in the daily cap" do
    CrawlRun.create!(source_kind: DqPass::TRIAL_KIND, stage: "verify", stats: { "llm" => { "cost" => 1.0 } })
    assert_not DqPass.budget_left?
  end
end
