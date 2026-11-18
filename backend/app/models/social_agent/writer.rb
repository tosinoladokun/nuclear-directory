# Drafts a post from an item and checks its voice (#769), through the existing OpenRouter client: the extract
# model writes, the verify model judges. The writer never adds a link; the agent appends the tracked one.
class SocialAgent::Writer
  RULES = <<~TEXT.freeze
    You write one post for Nuclear Directory's brand account, a free directory of the US nuclear industry.
    Rules (the Social playbook and VOICE.md):
    - Lead with the useful fact: who did what, with the number, date and conditions the facts give. Nothing else.
    - Use only the facts given. Every number and name must come from them. No guesses, rankings or opinions.
    - Keep distinctions: an award isn't a payment, a framework isn't a contract, proposed MW aren't output.
    - Plain and neutral. No hype, no questions to the reader, no calls to action, no "we", no hashtags,
      no emoji, no links, no exclamation marks, no "not X but Y", no lists of three for rhythm.
  TEXT
  LENGTH = { "x" => "One or two sentences, at most 220 characters.", "linkedin" => "Two short paragraphs, 60 to 120 words." }.freeze
  DRAFT = { type: "object", additionalProperties: false, required: %w[text], properties: { text: { type: "string" } } }.freeze
  JUDGE = { type: "object", additionalProperties: false, required: %w[pass reason],
            properties: { pass: { type: "boolean" }, reason: { type: "string" } } }.freeze

  def initialize(client: DataQuality::OpenRouter::Client.new)
    @client = client
  end

  def draft(item, platform:)
    facts = item.facts.map { |key, value| "#{key}: #{value}" }.join("\n")
    @client.structured(role: :extract, schema: DRAFT, schema_name: "post", messages: [
      { role: "system", content: "#{RULES}\n#{LENGTH.fetch(platform)}" },
      { role: "user", content: "Facts:\n#{facts}\n\nSource's words:\n#{item.source_quote}" }
    ]).data.fetch("text").strip
  end

  # The automated Founder-style check: true with nil, or false with why.
  def voice_ok?(text, item)
    data = @client.structured(role: :verify, schema: JUDGE, schema_name: "check", messages: [
      { role: "system", content: "You check a social post before it goes out. Pass it only if it follows every rule, " \
        "states nothing the facts don't, and reads like a careful trade reporter. Otherwise fail it and say why in one sentence.\n#{RULES}" },
      { role: "user", content: "Facts:\n#{item.facts.map { |key, value| "#{key}: #{value}" }.join("\n")}\n\nPost:\n#{text}" }
    ]).data
    [ data["pass"] == true, data["reason"] ]
  end
end
