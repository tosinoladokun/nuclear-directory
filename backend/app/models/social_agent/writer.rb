# Drafts a post from an item and checks its voice (#769), through the existing OpenRouter client: the extract
# model writes, the verify model judges. The writer never adds a link; the agent appends the tracked one.
class SocialAgent::Writer
  RULES = <<~TEXT.freeze
    You write one post for Nuclear Directory's brand account, a free directory of the US nuclear industry.
    Rules (the Social playbook and VOICE.md):
    - Lead with the useful fact: who did what, with the number, date and conditions the facts give. Nothing else.
    - Use only the facts given. Every number and name must come from them. No guesses, rankings or opinions.
    - Say who issued the source, not who it mentions: a regulator's letter or notice is the regulator's ("the NRC said", "in an
      NRC letter dated 19 October"), never "the company said". A permit, project number or acceptance is the agency's act.
    - Say what a deal or event covers, in the source's own terms (its purpose and field, "advanced nuclear energy"), not a
      generic "cooperation" or "knowledge exchange". Keep the conditions that bear on the claim made; don't pad with the rest.
    - A regulator's act keeps the source's verb: "approved" is not "authorized", "licensed" is not "permitted" or "cleared".
    - A dated event is told in the past tense ("signed", "announced"), never "signs" or "announces" beside a date.
    - A superlative (first, largest, only) is the source's claim: attribute it ("DOE calls it the first ...", "the company
      describes it as the largest ..."), never state it as fact.
    - Always say who the item comes from, in words ("the company said", "DOE said", "in a Federal Register notice"). The post's
      link is added for you and goes to our own page; never write the source's address or ask readers to follow a link.
    - Give the event's date ("On 12 November") rather than "today", "this week" or "just". When the facts name a
      publisher or regulator, say where it comes from in a short clause ("in a Federal Register notice", "DOE said").
    - Keep distinctions: an award isn't a payment, a framework isn't a contract, proposed MW aren't output. Keep the
      source's own qualifier on a deal (an MOU, non-binding, a letter of intent, a framework agreement).
    - Say what the source says it did, with its own verb and tense ("DOE announced a conditional commitment" when the
      source says announced). Never a status word the source doesn't use, and never stack verbs ("said it announced").
    - Write whole sentences: no fragments after a semicolon.
    - The date in the facts is when the source published the item: write "<publisher> said on <date> that ...",
      and give any other date only as the source states it (a deadline, a closing date).
    - Keep the conditions the source puts on what it reports (subject to approvals, does not commit to a project). A
      condition is its own fact, not a repetition: "non-binding" and "commits neither party to a project" can both stay.
    - Never say what the source doesn't say: no "no further details", "undisclosed" or "did not say".
    - Call the deal what the source calls it (an MOU is an MOU, not "a collaboration"), and name each party as the source
      names it, with the relationship it states ("Surbana Jurong Infrastructure, an SJ Group affiliate"); a legal ending
      such as Inc., Ltd. or Pte. Ltd. may be left off.
    - Say each thing once. When the facts are short, the post is short: never pad, restate the fact in other words,
      or repeat a name, label or purpose in an extra sentence.
    - Plain and neutral. No hype, no questions to the reader, no calls to action, no "we", no hashtags,
      no emoji, no links, no exclamation marks, no "not X but Y", no lists of three for rhythm.
  TEXT
  # What the voice check lets through (rehearsal rounds 1-11: these were blocked and are not problems). Anything that changes
  # what the source says still fails.
  NITS = <<~TEXT.freeze
    Do not fail a post for these:
    - a legal suffix left off a company name (Pte. Ltd., Ltd., Inc., LLC, GmbH);
    - the source's own qualifier beside the deal word, said once ("a non-binding MOU");
    - a plain synonym for the source's verb ("said", "announced") that keeps the meaning and every condition;
    - the source's own action verb ("announced", "signed") as the attribution: "said that" is not a required template;
    - future wording for what the source says will happen ("will add", "plans to", "is expected to"): that is correct, not an error.
    Before you say the post leaves out or changes something, find the exact words in the post. A word that is in the post
    ("nearly", "up to", "non-binding") is not missing. Quote the post's own offending words in your reason; if you cannot
    quote them, pass the post.
    Fail it when it changes what the source says, or adds, drops or contradicts a condition, number, name, date or party.
  TEXT
  LENGTH = { "x" => "One or two sentences, at most 220 characters.", "linkedin" => "One or two short paragraphs, at most 120 words; as short as the facts allow." }.freeze
  DRAFT = { type: "object", additionalProperties: false, required: %w[text], properties: { text: { type: "string" } } }.freeze
  JUDGE = { type: "object", additionalProperties: false, required: %w[pass reason],
            properties: { pass: { type: "boolean" }, reason: { type: "string" } } }.freeze

  def initialize(client: DataQuality::OpenRouter::Client.new)
    @client = client
  end

  # feedback/previous: a revision of a draft the checks stopped, with what stopped it.
  def draft(item, platform:, crawl_run: nil, feedback: nil, previous: nil)
    facts = item.facts.map { |key, value| "#{key}: #{value}" }.join("\n")
    revise = "\n\nYour earlier draft:\n#{previous}\n\nIt was stopped because: #{feedback}\nWrite it again, fixing that." if feedback
    @client.structured(role: :extract, schema: DRAFT, schema_name: "post", crawl_run:, messages: [
      { role: "system", content: "#{RULES}\n#{LENGTH.fetch(platform)}" },
      { role: "user", content: "Facts:\n#{facts}\n\nSource's words:\n#{item.source_quote}\n#{item.page_text}#{revise}" }
    ]).data.fetch("text").strip
  end

  # The automated Founder-style check: true with nil, or false with why.
  def voice_ok?(text, item, crawl_run: nil)
    data = @client.structured(role: :verify, schema: JUDGE, schema_name: "check", crawl_run:, messages: [
      { role: "system", content: "You check a social post before it goes out. Pass it only if it follows every rule, " \
        "states nothing the facts and the source's words don't, says nothing twice, has no filler sentence, and reads like a careful trade reporter. Otherwise fail it and say why in one sentence.\n#{RULES}\n#{NITS}" },
      { role: "user", content: "Facts:\n#{item.facts.map { |key, value| "#{key}: #{value}" }.join("\n")}\n\n" \
        "Source's words:\n#{item.source_quote}\n#{item.page_text}\n\nPost:\n#{text}" }
    ]).data
    [ data["pass"] == true, data["reason"] ]
  end
end
