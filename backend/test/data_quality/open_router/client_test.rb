require "test_helper"

class DataQuality::OpenRouter::ClientTest < ActiveSupport::TestCase
  ENDPOINT = "https://openrouter.ai/api/v1/chat/completions"
  SCHEMA = {
    "type" => "object",
    "properties" => { "name" => { "type" => "string" } },
    "required" => [ "name" ],
    "additionalProperties" => false
  }.freeze
  MESSAGES = [ { role: "user", content: "Who runs Vogtle?" } ].freeze

  setup do
    @sleeps = []
    config = DataQuality::Config.new(api_key: "test-key", extract_model: "vendor/extractor", verify_model: "vendor/verifier")
    @client = DataQuality::OpenRouter::Client.new(config: config, sleeper: ->(seconds) { @sleeps << seconds })
    @run = CrawlRun.create!(stage: "extract", source_kind: "dummy")
  end

  def completion(content, usage: { prompt_tokens: 100, completion_tokens: 20, total_tokens: 120, cost: 0.0012 })
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { model: "vendor/extractor", choices: [ { message: { content: content } } ], usage: usage }.to_json }
  end

  def ask(role: :extract)
    @client.structured(role: role, messages: MESSAGES, schema: SCHEMA, crawl_run: @run)
  end

  test "returns schema-valid JSON and records token usage on the crawl run" do
    stub = stub_request(:post, ENDPOINT)
      .with(headers: { "Authorization" => "Bearer test-key" }) { |request|
        body = JSON.parse(request.body)
        body["model"] == "vendor/extractor" && body.dig("response_format", "json_schema", "schema") == SCHEMA
      }
      .to_return(completion('{"name":"Southern Nuclear"}'))

    response = ask

    assert_requested stub
    assert_equal({ "name" => "Southern Nuclear" }, response.data)
    llm = @run.reload.stats["llm"]
    assert_equal 1, llm["calls"]
    assert_equal 120, llm["total_tokens"]
    assert_in_delta 0.0012, llm["cost"]
    assert_equal "vendor/extractor", @run.model
  end

  test "sends temperature and reasoning effort only when asked, since reasoning models refuse temperature" do
    bodies = []
    stub_request(:post, ENDPOINT).with { |request| bodies << JSON.parse(request.body) }.to_return(completion('{"name":"x"}'))

    ask
    @client.structured(role: :extract, messages: MESSAGES, schema: SCHEMA, temperature: 0, reasoning_effort: "low")

    assert_not bodies.first.key?("temperature"), "not sent by default"
    assert_not bodies.first.key?("reasoning")
    assert_equal [ 0, { "effort" => "low" } ], bodies.second.values_at("temperature", "reasoning")
    assert_equal({ "require_parameters" => true }, bodies.first["provider"])
  end

  test "the verify role uses the verifier model" do
    stub = stub_request(:post, ENDPOINT).with { |request| JSON.parse(request.body)["model"] == "vendor/verifier" }
      .to_return(completion('{"name":"x"}'))

    ask(role: :verify)

    assert_requested stub
  end

  test "rejects output that doesn't match the schema and retries" do
    stub_request(:post, ENDPOINT)
      .to_return(completion('{"nom":"wrong key"}'))
      .then.to_return(completion("```json\n{\"name\":\"Fenced\"}\n```"))

    assert_equal "Fenced", ask.data["name"]
    llm = @run.reload.stats["llm"]
    assert_equal 2, llm["calls"]
    assert_equal 1, llm["invalid_outputs"]
    assert_equal 1, llm["retries"]
    assert_equal 240, llm["total_tokens"], "tokens spent on the rejected attempt still count"
    assert_equal 1, @sleeps.size
  end

  test "backs off on rate limits, honoring Retry-After" do
    stub_request(:post, ENDPOINT)
      .to_return(status: 429, headers: { "Retry-After" => "7" }, body: { error: { message: "slow down" } }.to_json)
      .then.to_return(completion('{"name":"ok"}'))

    ask

    assert_equal [ 7 ], @sleeps
  end

  test "retries timeouts and server errors with growing delays, then gives up" do
    stub_request(:post, ENDPOINT).to_timeout.then.to_return(status: 502, body: "bad gateway").then.to_return(status: 503, body: "")

    error = assert_raises(DataQuality::OpenRouter::Client::RetriesExhausted) { ask }

    assert_match "after 3 attempts", error.message
    assert_requested :post, ENDPOINT, times: 3
    assert_equal 2, @sleeps.size
    assert @sleeps[0].between?(1.0, 1.25)
    assert @sleeps[1].between?(2.0, 2.5)
  end

  test "does not retry errors that retrying can't fix" do
    stub_request(:post, ENDPOINT).to_return(status: 401, body: { error: { message: "Invalid API key" } }.to_json)

    error = assert_raises(DataQuality::OpenRouter::Client::RequestError) { ask }

    assert_match "Invalid API key", error.message
    assert_requested :post, ENDPOINT, times: 1
    assert_empty @sleeps
  end

  test "a refused key or an empty account says what to fix (#188)" do
    stub_request(:post, ENDPOINT).to_return(status: 401, body: { error: { message: "User not found." } }.to_json)
    assert_equal "OpenRouter rejected the API key: check OPENROUTER_API_KEY (OpenRouter 401: User not found.)",
      assert_raises(DataQuality::OpenRouter::Client::RequestError) { ask }.message

    stub_request(:post, ENDPOINT).to_return(status: 402, body: { error: { message: "Insufficient credits" } }.to_json)
    assert_match "out of credit", assert_raises(DataQuality::OpenRouter::Client::RequestError) { ask }.message
  end

  # #192: 403 can be a key limit, a moderation refusal, an allowed-models
  # rule or an IP allowlist, so the prefix doesn't guess; OpenRouter's own
  # message says why.
  test "a 403 says it was refused and appends OpenRouter's reason, without guessing the cause (#192)" do
    stub_request(:post, ENDPOINT).to_return(status: 403, body: { error: { message: "Prompt flagged by moderation" } }.to_json)
    assert_equal "OpenRouter refused the request (OpenRouter 403: Prompt flagged by moderation)",
      assert_raises(DataQuality::OpenRouter::Client::RequestError) { ask }.message
  end

  test "checks the key without a model call" do
    key = stub_request(:get, "https://openrouter.ai/api/v1/key").with(headers: { "Authorization" => "Bearer test-key" })
      .to_return(status: 200, body: { data: { label: "nd-prod", usage: 0.07, limit: 10 } }.to_json)

    assert_equal({ label: "nd-prod", usage: 0.07, limit: 10 }, @client.check_key)
    assert_requested key
    assert_not_requested :post, ENDPOINT

    stub_request(:get, "https://openrouter.ai/api/v1/key").to_return(status: 401, body: { error: { message: "User not found." } }.to_json)
    assert_match "rejected the API key", assert_raises(DataQuality::OpenRouter::Client::RequestError) { @client.check_key }.message
  end

  test "treats an upstream error inside a 200 response as retryable" do
    stub_request(:post, ENDPOINT)
      .to_return(status: 200, body: { error: { code: 502, message: "provider down" } }.to_json)
      .then.to_return(completion('{"name":"ok"}'))

    assert_equal "ok", ask.data["name"]
  end

  test "refuses to start without a valid config" do
    bad = DataQuality::Config.new(api_key: nil, extract_model: "m", verify_model: "m")

    assert_raises(DataQuality::Config::ConfigurationError) { DataQuality::OpenRouter::Client.new(config: bad) }
  end
end
