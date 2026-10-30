# A plain headline and summary for every news claim (PM, 30 Oct), drafted
# once at extraction for all news plug-ins, from the source's own text
# (the plug-in's verification context, else the quote). The verifier then
# reads them in the claim's sentence and checks them against the source like
# any other fact.
#
# A headline the plug-in already wrote by rule (the Federal Register's) is
# kept. The summary is at most SUMMARY_LENGTH characters. When no model is
# configured, or the model fails or answers too long, the feed's own summary
# is kept, cut at a word to SUMMARY_LENGTH; nothing is made up.
class DataQuality::NewsDraft
  HEADLINE_LENGTH = 80
  SUMMARY_LENGTH = 160
  INSTRUCTIONS = <<~TEXT.freeze
    You write a headline and a one-sentence summary for a nuclear-industry news item, for a directory's "Latest" list.
    Use only facts stated in the text you are given. Never add a fact, number, date, name or claim the text doesn't state.
    Headline: at most #{HEADLINE_LENGTH} characters, sentence case, plain words, who did what. No clickbait, no quotes.
    Summary: one sentence, at most #{SUMMARY_LENGTH} characters, plain words, what happened and why it matters only if the text says so.
  TEXT
  SCHEMA = {
    type: "object", additionalProperties: false, required: %w[headline summary],
    properties: { headline: { type: "string" }, summary: { type: "string" } }
  }.freeze

  def self.llm=(client)
    @llm = client
  end

  # The model client, when one is configured (never in tests unless set).
  def self.llm
    return @llm if defined?(@llm) && @llm
    return unless DataQuality::Config.from_env.api_key

    DataQuality::OpenRouter::Client.new
  end

  def initialize(llm: self.class.llm)
    @llm = llm
  end

  # The extracted claims, each news item with its headline and summary.
  def apply(claims, plugin:, source:, run:)
    claims.map do |attrs|
      next attrs unless attrs[:kind].to_s == "news_item" && attrs[:payload].is_a?(Hash)
      # A lead never reaches the owner's Latest: no model call for it.
      next attrs if attrs[:payload]["lead"] == true

      attrs.merge(payload: drafted(attrs, plugin:, source:, run:))
    end
  end

  private
    def drafted(attrs, plugin:, source:, run:)
      payload = attrs[:payload].dup
      text = plugin.verification_context(source, attrs[:quote]).presence || attrs[:quote].to_s
      draft = draft_for(text, run) || {}
      headline = payload["headline"].presence || fit(draft["headline"], HEADLINE_LENGTH)
      summary = fit(draft["summary"], SUMMARY_LENGTH) || feed_summary(payload["summary"])
      payload.merge("headline" => headline, "summary" => summary).except(*([ "summary" ] unless summary))
    end

    def draft_for(text, run)
      return unless @llm && text.present?

      @llm.structured(role: :extract, schema: SCHEMA, schema_name: "news_draft", crawl_run: run, reasoning_effort: "low",
        messages: [ { role: "system", content: INSTRUCTIONS }, { role: "user", content: text.first(6_000) } ]).data
    rescue DataQuality::OpenRouter::Client::Error, DataQuality::Budget::Exceeded => error
      Rails.logger.warn("News draft skipped: #{error.class}: #{error.message}")
      nil
    end

    # The feed's own summary without a blog's "The post … appeared first on …"
    # tail, whole sentences up to SUMMARY_LENGTH; else none, never a clipped
    # half sentence (DQ, 30 Oct).
    APPEARED_FIRST = /\s*The post .+? appeared first on .+?\.?\s*\z/m
    def feed_summary(text)
      text = text.to_s.sub(APPEARED_FIRST, "").squish
      return if text.empty?
      return text if text.length <= SUMMARY_LENGTH && text.match?(/[.!?]["'”’)]?\z/)

      kept = text.scan(/[^.!?]+[.!?]["'”’)]?(?=\s|\z)/).map(&:strip).each_with_object([]) do |sentence, sentences|
        break sentences if (sentences + [ sentence ]).join(" ").length > SUMMARY_LENGTH

        sentences << sentence
      end
      kept.join(" ").presence
    end

    # The model's text, when it keeps to the limit; never cut.
    def fit(text, limit)
      text = text.to_s.squish
      text if text.present? && text.length <= limit
    end
end
