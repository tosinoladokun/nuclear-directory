# The nightly checker (#776): Data Quality's routine verdict on a claim, by a model, in shadow.
#
# Each night (DqCheckerJob, 10:00 UTC, after the crawl) it reads open claims it may judge, oldest first, and keeps one verdict each
# (approve, reject or unsure, with a short reason) in checker_verdicts. Nothing else changes: no
# recommendation is recorded and nothing is approved. After two weeks DQ compares them with its own and
# switches fields on one at a time (then verdicts go through Recommendations.record by "checker:<model>").
#
# - Code first: a claim it never judges, a contradicted one, a change to a value we hold, a company a
#   person rejected, no stored page or a quote that isn't on it are "unsure" without asking a model.
# - The cheap model (OPENROUTER_EXTRACT_MODEL) answers first; "unsure" goes to the verify model.
# - Code last: the hard rules can only lower an approve (to unsure), never raise anything.
# - Any error or the day's budget is "needs a human", never an approve.
# - At most LIMIT verdicts and DAILY_BUDGET dollars a day, counted from the database.
class DqChecker
  PROMPT_VERSION = "checker-v2"
  SOURCE_KIND = "dq_checker"
  LIMIT = 150
  DAILY_BUDGET = 1.0
  BATCH = 25
  WINDOW = 4_000
  # A whole call, retries included: OpenRouter's keep-alive bytes reset the read timeout, so one slow answer
  # held a call for six minutes in the exam.
  CALL_DEADLINE = 60
  KINDS = %w[organization organization_role news_item].freeze
  # What a claim fills, by its payload keys; anything else is never judged.
  FIELDS = {
    "hq_city" => "hq", "hq_state" => "hq", "legal_name" => "legal_name", "founded_year" => "founded_year",
    "description" => "description", "short_description" => "short_description", "website" => "website",
    "ticker" => "ticker", "exchange" => "ticker"
  }.freeze
  # Names shared by many companies or words: a website for one is never approved (DQ, 19 Nov).
  GENERIC = %w[natura aep candu fermi atlas].freeze
  # A row in an award list or a regulator's table names a company but isn't its own page: never enough to
  # approve a new company or a role (DQ, 20 Nov; DATA.md: nuclear work from its own page or a record stating it).
  ROW_SOURCES = /\A(usaspending|nrc_|arpa_e|doe_|federal_register|sec_)/
  OTHER_HOSTS = /(\A|\.)(linkedin|facebook|twitter|x|youtube|instagram|crunchbase|bloomberg|wikipedia|github|medium|businesswire|prnewswire|globenewswire)\.(com|org)\z/

  Claim = Data.define(:id, :kind, :payload, :quote, :page, :holding, :hold, :source_kind, :identity) do
    # identity: the stored page's address and its own names for itself, for a website claim (checker-v2); nil otherwise.
    def initialize(identity: nil, **) = super
    # :hold is why code decides it is unsure before any model reads it, or nil.
    def field = DqChecker.field_for(kind, payload)
  end
  Answer = Data.define(:verdict, :reason, :confidence, :model, :escalated)

  SCHEMA = {
    "type" => "object",
    "properties" => {
      "verdict" => { "type" => "string", "enum" => %w[approve reject unsure] },
      "reason" => { "type" => "string", "description" => "One plain line, under 140 characters" },
      "confidence" => { "type" => "number", "description" => "0 to 1" }
    },
    "required" => %w[verdict reason confidence],
    "additionalProperties" => false
  }.freeze

  INSTRUCTIONS = <<~TEXT.freeze
    You are the Data Quality checker for the Nuclear Directory, a public directory of the US nuclear industry.
    You judge ONE claim. You get the claim's kind and fields, the quote it cites, the text of the cited page
    around the quote, and what the directory already holds for this company. Answer with a verdict (approve,
    reject or unsure), a one-line reason in plain words under 140 characters, and a confidence from 0 to 1.
    Approve ONLY when ALL are true: (1) the page text itself states the fact in the claim; (2) the fact is
    about THIS company, not a parent, subsidiary, namesake or agent; (3) the company is American or its work is
    American, and it does nuclear work (fission, fusion, isotopes, fuel, waste, plants, or engineering,
    regulatory or financial work for them) as its page or an official record says; (4) for a blank fill, the
    directory holds nothing for this field; (5) it breaks none of these rules:
    - HQ: a city, with the state or country; the page must state the place; a subsidiary's, branch's or filing
      agent's registered address is not the HQ; several unmarked offices never are.
    - Description: says what the company does (nuclear work first for a broad company); no mission or vision
      lines, no division or product-line text, no praise.
    - Website: the https home page on the company's own domain only, never a parent's, a list's or a profile site's.
      A website claim is supported when the stored page IS the claimed site's home page (its host is the claimed
      domain) and that page names the company in its title, site name, main heading or logo. The page need not
      state its own URL. A page on another domain that merely mentions the company never supports its website.
    - No person names: never approve a value that names a person (a founder, an employee, a contact).
    - Role: from the company's own words.
    - News: the item must be about nuclear.
    Reject when the page says something different, names another company, the company isn't nuclear, the fact
    duplicates a better one, or it breaks a rule. Say which in the reason.
    Say unsure whenever you hesitate or the page is thin: a person then reads it, and that is often right.
    Never use outside knowledge to supply a fact the page doesn't state. Never approve a change to a value we hold.
  TEXT

  def self.field_for(kind, payload)
    case kind
    when "organization_role" then "role"
    when "news_item" then "news"
    when "organization"
      keys = payload.keys - %w[name aliases field_of]
      return "new_company" if keys.empty?

      fields = keys.map { |key| FIELDS[key] }
      fields.all? && fields.uniq.one? ? fields.first : "other"
    else kind
    end
  end

  # The CrawlRun model calls are counted on (the exam sets its own).
  attr_writer :run

  def initialize(llm: nil, now: Time.current)
    @llm = llm
    @now = now
  end

  # The night's run. Returns its summary hash (also kept on its CrawlRun).
  def run
    left = LIMIT - CheckerVerdict.today(@now).count
    return { "skipped" => "the day's #{LIMIT} verdicts are done" } unless left.positive?

    @run = CrawlRun.create!(source_kind: SOURCE_KIND, stage: "verify", prompt_version: PROMPT_VERSION, started_at: @now)
    counts = Hash.new(0)
    due.limit(left).find_in_batches(batch_size: BATCH) do |batch|
      batch.each do |candidate|
        if spent_today >= DAILY_BUDGET
          counts["stopped_for_budget"] = 1
          break
        end
        answer = judge(claim_for(candidate))
        CheckerVerdict.create!(candidate_id: candidate.id, crawl_run_id: @run.id, field: DqChecker.field_for(candidate.kind, candidate.payload),
          prompt_version: PROMPT_VERSION, **answer.to_h.slice(:verdict, :confidence, :model, :escalated), reason: answer.reason.truncate(200))
        counts[answer.verdict] += 1
      end
      break if counts["stopped_for_budget"].positive?
    end
    @run.finish!(stats: counts)
    counts
  rescue StandardError => error
    @run&.fail!(error.message.truncate(200))
    raise
  end

  # Open claims of the kinds it judges, with no DQ call and no verdict of this prompt yet; no page text loaded.
  def due
    Candidate.not_leads.where(status: DataQuality::Recommendations::OPEN, kind: KINDS, dq_recommendation: nil)
      .where.not(id: CheckerVerdict.where(prompt_version: PROMPT_VERSION).select(:candidate_id))
      .select(:id, :kind, :payload, :quote, :status, :source_id, :subject_type, :subject_id, :ai_reason)
      .order(:id)
  end

  def claim_for(candidate)
    org = company_of(candidate)
    source_kind = Source.where(id: candidate.source_id).pick(:source_kind)
    hold = hold_for(candidate, org)
    page = (window(candidate) unless hold)
    hold ||= "There's no stored page to read" if page.blank?
    hold ||= quote_hold(candidate, source_kind, page)
    identity = identity(candidate) if !hold && DqChecker.field_for(candidate.kind, candidate.payload) == "website"
    Claim.new(id: candidate.id, kind: candidate.kind, payload: candidate.payload, quote: candidate.quote, source_kind:, identity:,
      page:, holding: holding(org), hold:)
  end

  # The company a claim is about: its subject, a role's company, or (not matched yet) the one open or closed
  # company with exactly its name; nil when there's none or more than one.
  def company_of(candidate)
    case candidate.subject_type
    when "Organization" then return candidate.subject
    when "OrganizationRole" then return candidate.subject&.organization
    end
    name = (candidate.kind == "organization_role" ? candidate.payload.dig("organization", "name") : candidate.payload["name"]).to_s.squish
    return if name.blank?

    found = Organization.where("lower(name) = ?", name.downcase).limit(2).to_a
    found.first if found.one?
  end

  # The plug-in's own quote check when it has one (several read rows, not text), on pages up to MAX_CHECKED;
  # otherwise the quote must be in the window read from the stored page (Copilot, Infra).
  MAX_CHECKED = 1.megabyte

  def quote_hold(candidate, source_kind, page)
    plugin = (DataQuality::Plugin.for(source_kind) rescue nil)
    if plugin && plugin.method(:quote_in_source?).owner != DataQuality::Plugin
      size = Source.where(id: candidate.source_id).pick(Arel.sql("octet_length(content_text)")).to_i
      return "The page is too large to check its quote here" if size > MAX_CHECKED
      return if plugin.quote_in_source?(Source.find(candidate.source_id), candidate.quote)
    elsif DqChecker.quoted?(candidate.quote, page)
      return
    end
    "The quote isn't on the stored page"
  end

  # The checker's answer for one claim: code, then the models, then code.
  def judge(claim)
    return unsure(claim.hold) if claim.hold
    return unsure("Never judged by the checker (#{claim.field})") unless claim.field.in?(%w[new_company role news] + FIELDS.values)

    answer = ask(:extract, claim)
    answer = ask(:verify, claim).with(escalated: true) if answer.verdict == "unsure"
    answer.verdict == "approve" ? hard_rules(claim, answer) : answer
  rescue DataQuality::Budget::Exceeded
    unsure("Needs a human: the model budget is used up")
  rescue StandardError => error
    Rails.error.report(error, handled: true, context: { dq_checker: claim.id })
    unsure("Needs a human: the model didn't answer (#{error.class.name.demodulize})")
  end

  def self.quoted?(quote, page)
    quote = quote.to_s.squish.downcase
    quote.present? && page.to_s.squish.downcase.include?(quote)
  end

  # About WINDOW characters of the page around the quote, read in SQL so a page of several MB is never loaded
  # (Infra); the first WINDOW characters when the quote's start isn't found. Markup is dropped from the window only.
  def window(candidate)
    needle = candidate.quote.to_s.squish.first(60).downcase
    sql = ActiveRecord::Base.sanitize_sql_array([ "substring(content_text from greatest(position(? in lower(left(content_text, 1000000))) - ?, 1) for ?)",
      needle, WINDOW / 2, WINDOW ])
    text = Source.where(id: candidate.source_id).pick(Arel.sql(sql)).to_s
    text = Nokogiri::HTML.fragment(text).text if text.match?(/<\/?[a-z][^>]*>/i)
    text.squish.presence
  end

  # The stored page's address and how it names itself (title, og:site_name, first h1, header logo), each cut
  # short, read from the page's first IDENTITY_BYTES in SQL so a large page is never loaded (checker-v2, Copilot).
  IDENTITY_BYTES = 200_000
  IDENTITY_CHARS = 200

  def identity(candidate)
    url, final_url, head = Source.where(id: candidate.source_id).pick(:url, :final_url, Arel.sql("left(content_text, #{IDENTITY_BYTES})"))
    return if url.nil?

    doc = Nokogiri::HTML(head.to_s)
    logos = doc.css("header img[alt], nav img[alt]").select { |img| "#{img['src']} #{img['class']} #{img['id']} #{img['alt']}".match?(/logo/i) }
    { "Page address" => final_url.presence || url, "Page title" => doc.at_css("title")&.text,
      "Site name" => doc.at_css("meta[property='og:site_name']")&.[]("content"), "Main heading" => doc.at_css("h1")&.text,
      "Logo" => logos.map { |img| img["alt"] }.first }
      .filter_map { |label, value| "#{label}: #{value.to_s.squish.first(IDENTITY_CHARS)}" if value.present? }.join("\n")
  end

  def holding(org)
    return {} unless org

    org.attributes.slice("id", "name", "legal_name", "website", "hq_city", "hq_state", "country_code", "founded_year",
      "short_description", "description", "verification_status").compact
  end

  private
    def hold_for(candidate, org)
      return "The verifier says the source contradicts this" if candidate.ai_reason.to_s.start_with?(DataQuality::Verifiers::Agent::CONTRADICTS)
      field = DqChecker.field_for(candidate.kind, candidate.payload)
      return "Not matched to one company yet" if org.nil? && !field.in?(%w[new_company news])
      return unless org
      return "A person rejected or unpublished this company" if org.verification_status.in?(%w[rejected unpublished])

      changed = (candidate.payload.keys & FIELDS.keys).select { |key| org[key].present? && org[key].to_s != candidate.payload[key].to_s }
      "Changes a value we hold (#{changed.join(', ')})" if changed.any?
    end

    def ask(role, claim)
      response = Timeout.timeout(CALL_DEADLINE) { llm_call(role, claim) }
      data = response.data
      confidence = data["confidence"].is_a?(Numeric) && data["confidence"].between?(0, 1) ? BigDecimal(data["confidence"].to_s).floor(2) : nil
      verdict = data["verdict"].in?(CheckerVerdict::VERDICTS) && confidence ? data["verdict"] : "unsure"
      Answer.new(verdict:, reason: data["reason"].to_s.squish.presence || "No reason given", confidence:, model: response.model, escalated: false)
    end

    def llm_call(role, claim)
      # Before every call, the verify call after an unsure too (Copilot).
      raise DataQuality::Budget::Exceeded, "the day's checker budget is used" if spent_today >= DAILY_BUDGET

      llm.structured(role:, schema: SCHEMA, schema_name: "checker_verdict", crawl_run: @run, reasoning_effort: "low",
        messages: [ { role: "system", content: INSTRUCTIONS }, { role: "user", content: prompt(claim) } ])
    end

    def prompt(claim)
      "Claim kind: #{claim.kind} (#{claim.field})\nClaim: #{JSON.generate(claim.payload)}\n" \
        "What the directory holds for this company: #{claim.holding.any? ? JSON.generate(claim.holding) : 'nothing (a new company)'}\n" \
        "Quote: #{claim.quote}\n\n#{"The stored page:\n#{claim.identity}\n\n" if claim.identity.present?}Page text around the quote:\n#{claim.page}"
    end

    # The rules code decides, after a model's approve: each can only make it unsure.
    def hard_rules(claim, answer)
      why =
        case claim.field
        when "hq" then "No city in the claim" if claim.payload["hq_city"].blank?
        when "website" then website_rule(claim)
        when "new_company", "role"
          "Only an award or register row names it; nuclear work needs its own page" if claim.source_kind.to_s.match?(ROW_SOURCES)
        when "news" then "News only for companies we hold; this one isn't in the directory" unless held_news?(claim)
        end
      why ? unsure(why).with(model: answer.model, escalated: answer.escalated) : answer
    end

    # Every company the item is about is in the directory, published or pending (DQ, 20 Nov).
    def held_news?(claim)
      names = Array(claim.payload["about"]).select { |about| about["type"].to_s == "organization" }.map { |about| about["name"].to_s.squish.downcase }
      return false if names.empty? || names.any?(&:blank?)

      open = Organization.where(verification_status: %w[verified pending])
      names.all? do |name|
        open.where("lower(name) = ?", name).exists? ||
          open.where(id: OrganizationAlias.where("lower(alias) = ?", name).select(:organization_id)).exists?
      end
    end

    def website_rule(claim)
      uri = URI.parse(claim.payload["website"].to_s) rescue nil
      return "Not an https home page" unless uri&.scheme == "https" && uri.path.to_s.delete("/").empty? && uri.query.nil?

      host = uri.host.to_s.downcase.delete_prefix("www.")
      return "A social, news or aggregator site, not the company's own" if host.match?(OTHER_HOSTS)

      others = Organization.where("lower(website) ~ ?", "^https?://(www\\.)?#{Regexp.escape(host)}(/|$)")
      others = others.where.not(id: claim.holding["id"]) if claim.holding["id"]
      return "Another company already has this site" if Organization.exists?(others.select(:id)) && claim.holding["website"].blank?

      name = claim.holding["name"].presence || claim.payload["name"].to_s
      return "The name is shared by many companies" if name.downcase.split(/\W+/).intersect?(GENERIC)

      # checker-v2 (DQ, 27 Nov): the stored page must BE the claimed site's own home page, named as the company's own.
      # Its size first, so a page of several MB is never loaded here (Copilot).
      source_id = Candidate.where(id: claim.id).pick(:source_id)
      return "The page is too large to check its site here" if Source.where(id: source_id).pick(Arel.sql("octet_length(content_text)")).to_i > MAX_CHECKED

      page = Source.find_by(id: source_id)
      page_host = (URI.parse(page.final_url.presence || page.url).host.to_s.downcase.delete_prefix("www.") rescue nil) if page
      return "The stored page isn't the claimed site's own page" unless page_host == host

      names = [ name, *OrganizationAlias.where(organization_id: claim.holding["id"]).pluck(:alias) ]
      return "The page doesn't name the company as its own site" unless DataQuality::Plugins::LeadFinder.new(search_key: nil).own_site_for?(page, names)

      brand = name.split(/\W+/).find { |word| word.length >= 4 }
      named = [ name, brand ].compact.any? { |text| claim.quote.to_s.match?(/(?<![[:alnum:]])#{Regexp.escape(text)}(?![[:alnum:]])/i) }
      "The quote doesn't name the company" unless named
    end

    def unsure(reason) = Answer.new(verdict: "unsure", reason:, confidence: nil, model: nil, escalated: false)

    # Counted from the database (crawl_runs stats), never a cache: every checker run started today, UTC.
    def spent_today
      CrawlRun.where(source_kind: SOURCE_KIND, started_at: @now.utc.beginning_of_day..).sum("COALESCE((stats->'llm'->>'cost')::numeric, 0)").to_f
    end

    # Read 30 s, two attempts (Infra), the same OpenRouter key and monthly budget as the pipeline.
    def llm
      @llm ||= begin
        config = DataQuality::Config.from_env
        DataQuality::OpenRouter::Client.new(config: DataQuality::Config.new(api_key: config.api_key, extract_model: config.extract_model,
          verify_model: config.verify_model, monthly_budget: config.monthly_budget, read_timeout: 30, max_attempts: 2))
      end
    end
end
