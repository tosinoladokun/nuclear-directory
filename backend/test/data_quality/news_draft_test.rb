require "test_helper"

class DataQuality::NewsDraftTest < ActiveSupport::TestCase
  FakeLLM = Struct.new(:data, :seen) do
    def structured(messages:, **)
      self.seen = messages.last[:content]
      Struct.new(:data).new(data)
    end
  end
  Plugin = Struct.new(:context) do
    def verification_context(_source, _quote) = context
  end

  def news(payload = {}) = { kind: "news_item", quote: "Acme Starts Reactor Build", payload: { "title" => "Acme Starts Reactor Build", "summary" => "x " * 200 }.merge(payload) }
  def apply(llm, claims, context: "Acme Starts Reactor Build\n2026-10-01\nAcme began building its first reactor in Texas.")
    DataQuality::NewsDraft.new(llm:).apply(claims, plugin: Plugin.new(context), source: nil, run: nil)
  end

  test "a news claim gets the model's headline and summary, drafted from the source's own text" do
    llm = FakeLLM.new({ "headline" => "Acme begins building its first reactor", "summary" => "Acme began building its first reactor in Texas." })
    payload = apply(llm, [ news ]).sole[:payload]

    assert_equal [ "Acme begins building its first reactor", "Acme began building its first reactor in Texas." ], payload.values_at("headline", "summary")
    assert_match "began building its first reactor in Texas", llm.seen
  end

  test "a rule-based headline is kept; too-long model text is never cut, the feed's summary is" do
    llm = FakeLLM.new({ "headline" => "h" * 81, "summary" => "s" * 161 })
    payload = apply(llm, [ news("headline" => "Exemption: Pioneer Units 1 and 2") ]).sole[:payload]

    assert_equal "Exemption: Pioneer Units 1 and 2", payload["headline"]
    assert_operator payload["summary"].length, :<=, DataQuality::NewsDraft::SUMMARY_LENGTH
    assert payload["summary"].start_with?("x x")
  end

  test "no model: the feed's summary cut to 160, no headline made up; other claims and leads untouched" do
    company = { kind: "organization", quote: "q", payload: { "name" => "Acme" } }
    lead = news("lead" => true)
    drafted, untouched, lead_out = apply(nil, [ news, company, lead ])

    assert_nil drafted[:payload]["headline"]
    assert_operator drafted[:payload]["summary"].length, :<=, 160
    assert_equal company, untouched
    assert_equal lead, lead_out
  end
end
