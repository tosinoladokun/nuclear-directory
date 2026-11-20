# The checker's models in tests (#776): answers by role from a list; records what it was asked.
class FakeCheckerLlm
  attr_reader :asked

  def initialize(extract: [], verify: [], error: nil)
    @answers = { extract:, verify: }
    @error = error
    @asked = []
  end

  def structured(role:, messages:, crawl_run: nil, **)
    @asked << [ role, messages.last[:content] ]
    raise @error if @error

    crawl_run&.update!(stats: crawl_run.stats.merge("llm" => { "cost" => crawl_run.stats.dig("llm", "cost").to_f + 0.01 }))
    verdict, reason = @answers.fetch(role).shift || [ "unsure", "no more answers" ]
    DataQuality::OpenRouter::Client::Response.new(data: { "verdict" => verdict, "reason" => reason, "confidence" => 0.9 }, model: "fake-#{role}", usage: {})
  end
end
