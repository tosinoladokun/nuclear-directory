require "net/http"

# Calls an LLM through OpenRouter and returns JSON that matches a schema.
#
#   client = DataQuality::OpenRouter::Client.new
#   response = client.structured(role: :extract, schema: SCHEMA, crawl_run: run,
#     messages: [ { role: "user", content: "..." } ])
#   response.data # => parsed, schema-valid Hash
#
# The role picks the model (extract and verify use different ones; see
# DataQuality::Config). Timeouts, rate limits, server errors and output that
# doesn't match the schema are retried with exponential backoff. Token usage
# of every attempt is added to crawl_run.stats["llm"].
class DataQuality::OpenRouter::Client
  ENDPOINT = URI("https://openrouter.ai/api/v1/chat/completions")
  RETRYABLE_STATUSES = [ 408, 429, 500, 502, 503, 504 ].freeze
  NETWORK_ERRORS = [ Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED,
    Errno::EHOSTUNREACH, SocketError, EOFError, OpenSSL::SSL::SSLError ].freeze
  MAX_RETRY_AFTER = 60
  KEY_ENDPOINT = URI("https://openrouter.ai/api/v1/key")
  # Failures a person fixes on the account, said plainly in the run's error
  # and in data_quality:status (#188: a bad key read "401: User not found").
  ACCOUNT_PROBLEMS = {
    401 => "OpenRouter rejected the API key: check OPENROUTER_API_KEY",
    402 => "OpenRouter says the account is out of credit: add credit or raise the key's limit",
    # 403 can mean a key limit, an allowed-models rule, a moderation refusal,
    # or an IP allowlist (#192), so the prefix stays cause-neutral and
    # OpenRouter's own message, appended below, says why.
    403 => "OpenRouter refused the request"
  }.freeze

  class Error < StandardError; end
  # Bad request, bad key, unknown model: retrying won't help.
  class RequestError < Error; end
  # Still failing (network, rate limit, invalid output) after every attempt.
  class RetriesExhausted < Error; end

  Response = Data.define(:data, :model, :usage)

  # A failure worth another attempt.
  class Retryable < StandardError
    attr_reader :retry_after

    def initialize(message, retry_after: nil)
      super(message)
      @retry_after = retry_after
    end
  end

  def initialize(config: DataQuality::Config.from_env, sleeper: ->(seconds) { sleep seconds })
    @config = config.validate!
    @sleeper = sleeper
  end

  # A free check that the key works: OpenRouter's key endpoint, no model
  # call. Returns the key's label, usage and limit (dollars); raises
  # RequestError with ACCOUNT_PROBLEMS' wording when it's refused.
  def check_key
    request = Net::HTTP::Get.new(KEY_ENDPOINT)
    request["Authorization"] = "Bearer #{@config.api_key}"
    response = Net::HTTP.start(KEY_ENDPOINT.host, KEY_ENDPOINT.port, use_ssl: true,
      open_timeout: @config.open_timeout, read_timeout: @config.read_timeout) { |http| http.request(request) }
    data = handle(response).fetch("data", {})
    { label: data["label"], usage: data["usage"], limit: data["limit"] }
  rescue *NETWORK_ERRORS => error
    raise RequestError, "Couldn't reach OpenRouter: #{error.class}: #{error.message}"
  rescue Retryable => error
    raise RequestError, error.message
  end

  # temperature and reasoning_effort ("low", "medium", "high") are only sent
  # when given: every parameter sent must be supported by the model, since
  # require_parameters makes OpenRouter refuse ("No endpoints found")
  # rather than drop one. Reasoning models (e.g. gpt-6-luna, claude-haiku-5.5)
  # don't take temperature.
  def structured(role:, messages:, schema:, schema_name: "result", crawl_run: nil, temperature: nil, reasoning_effort: nil)
    model = @config.model_for(role)
    body = {
      model: model,
      messages: messages,
      temperature: temperature,
      reasoning: reasoning_effort && { effort: reasoning_effort },
      response_format: { type: "json_schema", json_schema: { name: schema_name, strict: true, schema: schema } },
      # Only route to providers that support everything above, so structured
      # output is never silently dropped.
      provider: { require_parameters: true },
      usage: { include: true }
    }.compact
    validator = JSONSchemer.schema(schema)

    with_retries do |attempt|
      # Before every attempt, retries included; raises Budget::Exceeded.
      DataQuality::Budget.check!(@config.monthly_budget)
      payload = post(body)
      record_usage(crawl_run, model, payload["usage"], attempt:)

      content = payload.dig("choices", 0, "message", "content")
      data = parse_json(content)
      errors = validator.validate(data).map { |e| e["error"] }
      if errors.any?
        record_invalid_output(crawl_run)
        raise Retryable, "Output didn't match the schema: #{errors.first(3).join('; ')}"
      end

      Response.new(data: data, model: payload["model"] || model, usage: payload["usage"] || {})
    end
  end

  private
    def with_retries
      attempt = 0
      begin
        attempt += 1
        yield attempt
      rescue Retryable => error
        raise RetriesExhausted, "Gave up after #{attempt} attempts: #{error.message}" if attempt >= @config.max_attempts

        @sleeper.call(error.retry_after || backoff(attempt))
        retry
      end
    end

    # 1s, 2s, 4s… plus up to 25% jitter so parallel workers don't retry in lockstep.
    def backoff(attempt)
      delay = @config.base_delay * (2**(attempt - 1))
      delay + (delay * 0.25 * rand)
    end

    def post(body)
      request = Net::HTTP::Post.new(ENDPOINT)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["Content-Type"] = "application/json"
      request["HTTP-Referer"] = "https://nuclear-directory.org"
      request["X-Title"] = "Nuclear Directory"
      request.body = body.to_json

      response = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true,
        open_timeout: @config.open_timeout, read_timeout: @config.read_timeout) { |http| http.request(request) }

      handle(response)
    rescue *NETWORK_ERRORS => error
      raise Retryable, "Network error: #{error.class}: #{error.message}"
    end

    def handle(response)
      status = response.code.to_i
      payload = parse_body(response.body)
      message = payload.dig("error", "message") || response.body.to_s.truncate(200)

      if RETRYABLE_STATUSES.include?(status)
        raise Retryable.new("OpenRouter #{status}: #{message}", retry_after: retry_after(response))
      end
      raise RequestError, "#{ACCOUNT_PROBLEMS[status]} (OpenRouter #{status}: #{message})" if ACCOUNT_PROBLEMS.key?(status)
      raise RequestError, "OpenRouter #{status}: #{message}" unless status.between?(200, 299)

      # OpenRouter can return 200 with an error from the upstream provider.
      if (error = payload["error"])
        code = error["code"].to_i
        raise RequestError, "OpenRouter error #{code}: #{message}" unless RETRYABLE_STATUSES.include?(code) || code.zero?

        raise Retryable, "OpenRouter error #{code}: #{message}"
      end

      payload
    end

    def parse_body(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def parse_json(content)
      raise Retryable, "Empty response" if content.blank?

      # Some models wrap JSON in a ```json fence despite being asked not to.
      JSON.parse(content.strip.delete_prefix("```json").delete_prefix("```").delete_suffix("```"))
    rescue JSON::ParserError => error
      raise Retryable, "Response wasn't valid JSON: #{error.message.truncate(100)}"
    end

    def retry_after(response)
      seconds = response["Retry-After"].to_s
      seconds.match?(/\A\d+\z/) ? [ seconds.to_i, MAX_RETRY_AFTER ].min : nil
    end

    def record_usage(run, model, usage, attempt:)
      return unless run

      llm = run.stats.fetch("llm", {})
      # A run that recorded calls before by_month existed (in flight across
      # a deploy) moves those totals into the month it started, so its
      # earlier spend isn't lost once its first monthly bucket appears.
      if llm["by_month"].nil? && llm["calls"].to_i.positive?
        llm["by_month"] = { run.started_at.strftime("%Y-%m") =>
          { "calls" => llm["calls"].to_i, "total_tokens" => llm["total_tokens"].to_i, "cost" => llm["cost"].to_f } }
      end
      llm["calls"] = llm.fetch("calls", 0) + 1
      llm["retries"] = llm.fetch("retries", 0) + 1 if attempt > 1
      %w[prompt_tokens completion_tokens total_tokens].each do |key|
        llm[key] = llm.fetch(key, 0) + usage.to_h.fetch(key, 0).to_i
      end
      llm["cost"] = (llm.fetch("cost", 0) + usage["cost"].to_f).round(6) if usage.to_h["cost"]

      # Also by the calendar month of the call, so a run that crosses
      # midnight at month end is counted in the right month (Budget,
      # StatusReport): "by_month" => { "2026-10" => { calls, total_tokens, cost } }
      month = (llm["by_month"] ||= {})[Time.current.strftime("%Y-%m")] ||= { "calls" => 0, "total_tokens" => 0, "cost" => 0 }
      month["calls"] += 1
      month["total_tokens"] += usage.to_h.fetch("total_tokens", 0).to_i
      month["cost"] = (month["cost"] + usage.to_h["cost"].to_f).round(6)

      run.update!(stats: run.stats.merge("llm" => llm), model: run.model || model)
    end

    def record_invalid_output(run)
      return unless run

      llm = run.stats.fetch("llm", {})
      llm["invalid_outputs"] = llm.fetch("invalid_outputs", 0) + 1
      run.update!(stats: run.stats.merge("llm" => llm))
    end
end
