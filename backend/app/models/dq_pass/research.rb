# Data Quality's pass, research (#998): with a model, for a pending company
# code couldn't settle, to propose its website and a role. It only proposes
# (Matching's propose_fields and propose_role, as DQ's API does); Tosin
# still decides.
#
# - Which: real pending companies (none Data Quality said no to) with no
#   website or no role, none proposed yet, and for one with no website only
#   after the lead finder searched for it (code first). Each at most once a
#   week (RETRY_AFTER), at most PER_NIGHT a night, oldest first.
# - Pages: its website's home page, or Brave's first candidates (the lead
#   finder's search, its daily limit). Only the page's main text goes to the
#   model, cut to PAGE_CHARS: no nav, footer, scripts or forms.
# - Models: the cheap one first (DQ_PASS_CHEAP_MODEL); the strong one
#   (DQ_PASS_STRONG_MODEL) only when the cheap one isn't sure. The daily cap
#   (DqPass.check_budget!) before every call.
# - Code last: a website must be one of the pages read, no other company's,
#   and its quote word for word on that page and naming the company; a
#   role's key must exist and its quote be word for word on a page read. No
#   HQ or description: those stay with a person (DQ's exam, 27 Nov).
# - A reject (out of scope) only when the strong model says so, as a
#   recommendation on its open company claims.
class DqPass::Research
  PER_NIGHT = 15
  RETRY_AFTER = 7.days
  PAGE_CHARS = 6_000
  RECORD_CHARS = 400
  CANDIDATES = 2
  CHEAP = "anthropic/claude-haiku-5.5".freeze
  STRONG = "anthropic/claude-sonnet-5.5".freeze
  MAIN_DROP = "script, style, noscript, nav, footer, form, iframe, svg, aside".freeze

  SCHEMA = {
    "type" => "object",
    "properties" => {
      "website" => { "type" => [ "string", "null" ], "description" => "One of the page URLs given, exactly, or null" },
      "website_quote" => { "type" => [ "string", "null" ], "description" => "Words copied exactly from that page that name the company" },
      "role" => { "type" => [ "string", "null" ], "description" => "One role key from the list, or null" },
      "role_quote" => { "type" => [ "string", "null" ], "description" => "Words copied exactly from a page given that state that work" },
      "out_of_scope" => { "type" => "boolean", "description" => "True only if the pages show it does no nuclear work at all" },
      "sure" => { "type" => "boolean" },
      "reason" => { "type" => "string", "description" => "One plain line, under 140 characters" }
    },
    "required" => %w[website website_quote role role_quote out_of_scope sure reason],
    "additionalProperties" => false
  }.freeze

  INSTRUCTIONS = <<~TEXT.freeze
    You research ONE company for the Nuclear Directory, a public directory of the US nuclear industry. You get its
    name, short records that mention it, and the main text of one or two web pages. Answer from those pages only;
    never from outside knowledge.
    - website: the URL of the page given that is the company's OWN home page (not a parent's, a customer's, a news
      or profile site's), or null. website_quote: words copied exactly from that page that name the company.
    - role: the one role key from the list that the company's own page states as its nuclear work, or null.
      role_quote: words copied exactly from a page given that state it. A utility, an operator, a lab or a
      university is what the page says it is. Engineering or maintenance services for nuclear plants are
      reactor_services, not project_developer. A part or equipment maker is components. A fusion developer (it
      designs or builds a fusion machine or power plant) is reactor_vendor. Engineering, construction or EPC firms
      are reactor_services, even when they also do waste or decommissioning work.
    - out_of_scope: true only when the company's own page shows it does no nuclear work at all.
    - sure: false whenever you hesitate, the pages are thin, or the page may be another company's. Say why in reason.
    Copy quotes character for character; never shorten, join or fix them.
  TEXT

  # The CrawlRun model calls are counted on (the trial sets its own).
  attr_writer :run

  # llm: anything with structured(...) (nil: OpenRouter). apply: Matching.apply. dry_run: propose nothing.
  def initialize(llm: nil, finder: nil, apply: ->(rows) { DataQuality::Matching.apply(rows) }, dry_run: false, now: Time.current)
    @llm, @finder, @apply, @dry_run, @now = llm, finder, apply, dry_run, now
  end

  # The night's research. Returns counts; the companies read go in the run's stats ("researched").
  def call(run)
    @run = run
    counts = Hash.new(0)
    due.each do |org|
      result = begin
        research(org)
      rescue DataQuality::OpenRouter::Client::Error => e
        # One company's failed model call (an error, an invalid answer) is that company's, not the night's.
        Rails.error.report(e, handled: true, context: { dq_pass_research: org.id })
        { outcome: "error" }
      end
      run.update!(stats: run.stats.merge("researched" => (run.stats["researched"].to_a + [ org.id ]).uniq))
      # The count under its own key: "researched" holds the companies' ids, which the weekly retry reads (Copilot).
      counts["research_count"] += 1
      counts["research_#{result[:outcome]}"] += 1
    end
    counts.to_h
  end

  # Pending companies research is for, oldest first.
  def due(limit: PER_NIGHT)
    open = Candidate.where(status: DataQuality::Recommendations::OPEN)
    site_claims = open.where(kind: "organization").where("payload ? 'website'").pluck(Arel.sql("lower(payload->>'name')")).to_set
    role_claims = open.where(kind: "organization_role").pluck(Arel.sql("lower(payload->'organization'->>'name')")).to_set
    tried = CrawlRun.where(source_kind: [ DqPass::SOURCE_KIND ], started_at: (@now - RETRY_AFTER)..)
      .pluck(Arel.sql("stats->'researched'")).flatten.compact.map(&:to_i).to_set
    site_for = DataQuality::Plugins::LeadFinder::SITE_FOR
    searched = CrawlRun.where(source_kind: "lead_finder", stage: "crawl").where("stats ? '#{site_for}'")
      .pluck(Arel.sql("(stats->>'#{site_for}')::bigint")).to_set
    junk = Candidate.where(subject_type: "Organization", kind: "organization", dq_recommendation: "reject").select(:subject_id)
    roled = OrganizationRole.distinct.pluck(:organization_id).to_set
    Organization.where(verification_status: "pending").where.not(id: junk).order(:id).to_a.select do |org|
      next false if tried.include?(org.id)

      name = org.name.downcase
      needs_site = org.website.blank? && !site_claims.include?(name)
      needs_role = !roled.include?(org.id) && !role_claims.include?(name)
      (needs_site && searched.include?(org.id)) || (needs_role && org.website.present?)
    end.first(limit)
  end

  # One company: read, ask, check, propose. Returns { outcome:, answer:, proposed:, errors: }.
  def research(org)
    pages = pages_for(org)
    # No page of its own: no model is asked (DQ's trial).
    return { outcome: "no_own_page", answer: nil, proposed: [], errors: [] } if pages.empty?

    answer = ask(:extract, org, pages)
    answer = ask(:verify, org, pages).merge("escalated" => true) unless answer["sure"]
    return { outcome: "unsure", answer:, proposed: [], errors: [] } unless answer["sure"]

    rows = rows_for(org, pages, answer)
    return { outcome: "nothing", answer:, proposed: [], errors: [] } if rows.empty?
    return { outcome: "would_propose", answer:, proposed: rows, errors: [] } if @dry_run

    results = @apply.call(rows)
    { outcome: results.any?(&:ok) ? "proposed" : "refused", answer:, proposed: rows, errors: results.reject(&:ok).map(&:error) }
  end

  # Hosts that are never a company's own site: news and wires, profiles and
  # aggregators, and government or university sites (unless the company is
  # that body, by name: a lab, an agency, a university). DQ's trial, 27 Nov:
  # 13 of 20 searches gave only such pages.
  NEVER_OWN = /(?:\A|\.)(?:prnewswire|businesswire|globenewswire|accessnewswire|world-nuclear-news|ans|nucnet|neimagazine|utilitydive|reuters|bloomberg|yahoo|linkedin|twitter|x|facebook|youtube|instagram|wikipedia|crunchbase|github|medium|cision|factrail|interconnection|google|sec)\.[a-z.]+\z/
  PUBLIC_BODY = /\b(?:universit(?:y|ies)|college|institute|laboratory|laboratories|national lab|department|agency|administration|authority|commission)\b/i

  # The company's own home pages to read, at most CANDIDATES: its website;
  # else the website a claim already proposes, then its claims' own record
  # pages; then Brave's results. Only a page that is the company's own site
  # (the lead finder's own_site_for?, under its name or an alias) is kept, so
  # no model reads another party's page (DQ's trial: most of the spend).
  def pages_for(org)
    names = names_of(org)
    # Its stored website gets the same host and ownership checks as any other candidate (Copilot).
    return [ own_page(org, home(org.website), names:) ].compact if org.website.present? && allowed_host?(org, home(org.website).to_s)
    return [] if org.website.present?

    # What it already holds first; Brave only when none of those is a usable page of its own (Copilot).
    own = known_candidates(org).lazy.filter_map { |url| own_page(org, url, names:) }.first(CANDIDATES)
    return own if own.any?

    searched(org).lazy.filter_map { |url| own_page(org, url, names:) }.first(CANDIDATES)
  end

  # The website a claim proposes for it (attached to it, or a field proposal still targeted at it through Data
  # Quality's live action; Copilot), then its claims' own record pages.
  def known_candidates(org)
    claims = Candidate.where(kind: "organization", subject_type: "Organization", subject_id: org.id).includes(:source).order(:id).to_a
    targeted = Candidate.where(kind: "organization", status: DataQuality::Recommendations::OPEN,
      id: DqAction.live.where(action: "propose_fields", target_type: "Organization", target_id: org.id).select(:candidate_id)).to_a
    proposed = (claims + targeted).filter_map { |claim| claim.payload.to_h["website"] if claim.payload.to_h["website"].is_a?(String) }
    records = claims.filter_map { |claim| claim.source&.url }
    (proposed + records).filter_map { |url| home(url) }.uniq.select { |url| allowed_host?(org, url) }
  end

  def searched(org) = finder.search_sites(org.name).to_a.filter_map { |url| home(url) }.uniq.select { |url| allowed_host?(org, url) }

  def allowed_host?(org, url)
    host = URI.parse(url).host.to_s.downcase
    return false if host.match?(NEVER_OWN)
    return org.name.to_s.match?(PUBLIC_BODY) if host.end_with?(".gov", ".edu", ".mil")

    true
  rescue URI::Error
    false
  end

  def own_page(org, url, names:)
    page = url && finder.read_page(url) or return
    return unless finder.own_site_for?(page, names)

    { url: home(page.final_url.presence || page.url) || url, title: page.title.to_s.squish, text: main_text(page.content_text), source: page }
  end

  def names_of(org) = [ org.name, *OrganizationAlias.where(organization_id: org.id).pluck(:alias) ]

  # The page's main text: <main> or <article> when there is one, else the body, without nav, footer, scripts or forms.
  def main_text(html)
    doc = Nokogiri::HTML(html.to_s)
    doc.css(MAIN_DROP).each(&:remove)
    node = doc.at_css("main") || doc.at_css("article") || doc.at_css("body") || doc
    node.text.squish.first(PAGE_CHARS)
  end

  # The proposals an answer allows, after code's checks. A role or a reject
  # comes only from the company's own page: its website's, or the page
  # accepted as its website now; never another company's page that Brave
  # found (DQ, #1005).
  def rows_for(org, pages, answer)
    rows = []
    site = answer["website"].presence && pages.find { |page| page[:url] == home(answer["website"]) }
    accepted = org.website.blank? && site && website_ok?(org, site, answer["website_quote"]) ? site : nil
    if accepted
      rows << { "action" => "propose_fields", "target" => org.id, "fields" => { "website" => accepted[:url] }, "source_url" => accepted[:url],
        "quote" => answer["website_quote"], "reason" => reason(answer, "its own home page"), "request_key" => key(org, "website") }
    end
    # With a website, the one page read is its home page, wherever it redirected within the site (the Fetcher
    # keeps redirects on the same site; Copilot): never compared by its URL string.
    own = org.website.present? ? pages.first : accepted
    return rows unless own

    role = answer["role"].to_s
    if role.present? && self.class.quoted?(answer["role_quote"], own[:text]) && !OrganizationRole.where(organization_id: org.id).exists? &&
        directory.role_key?(role)
      rows << { "action" => "propose_role", "target" => org.id, "role" => role, "source_url" => own[:url], "quote" => answer["role_quote"],
        "reason" => reason(answer, "its own page states the work"), "request_key" => key(org, "role:#{role}") }
    end
    # A reject only on the strong model's word, and never for those Data Quality keeps from rejects.
    if answer["out_of_scope"] && answer["escalated"] && !DqPass.never_reject?(org)
      Candidate.where(kind: "organization", subject_type: "Organization", subject_id: org.id, status: DataQuality::Recommendations::OPEN,
        dq_recommendation: nil).order(:id).each do |claim|
        rows << { "action" => "recommend", "id" => claim.id, "verdict" => "reject", "reason" => reason(answer, "out of scope"),
          "request_key" => "dq-pass:research-reject:#{claim.id}" }
      end
    end
    rows
  end

  # The quote word for word in the text (case and spacing aside), and long enough to mean something.
  def self.quoted?(quote, text)
    quote = quote.to_s.squish.downcase
    quote.length >= 8 && text.to_s.squish.downcase.include?(quote)
  end

  private
    # The company's own site, by the lead finder's own test (#985: its title,
    # site name, first h1, header logo or address names it; never a staging
    # host, which read_page refuses), under its name or an alias; the quote
    # word for word on that page and naming it; and no other company's site.
    def website_ok?(org, page, quote)
      names = [ org.name, *OrganizationAlias.where(organization_id: org.id).pluck(:alias) ]
      return false unless finder.own_site_for?(page[:source], names)
      return false unless self.class.quoted?(quote, page[:text]) || self.class.quoted?(quote, page[:title])
      return false unless names.any? { |name| quote.to_s.downcase.include?(brand(name).downcase) } || short_form_ok?(org, page, quote)

      host = URI.parse(page[:url]).host.to_s.downcase.delete_prefix("www.")
      !Organization.where.not(id: org.id).where("lower(website) ~ ?", "^https?://(www\\.)?#{Regexp.escape(host)}(/|$)").exists?
    rescue URI::Error
      false
    end

    def short_form_ok?(org, page, quote)
      own_names = [ page[:title], *(page[:source] ? finder.site_names(page[:source]) : []) ]
      DataQuality::ShortForm.names?(name: org.name, quote:, own_names:, host: URI.parse(page[:url]).host)
    rescue URI::Error
      false
    end

    def brand(name) = name.to_s.squish.sub(/[,\s]+(?:inc|llc|corp|corporation|co|company|ltd|limited)\.?\z/i, "")

    def ask(role, org, pages)
      DqPass.check_budget!(now: @now)
      response = llm.structured(role:, schema: SCHEMA, schema_name: "dq_pass_research", crawl_run: @run, reasoning_effort: "low",
        messages: [ { role: "system", content: INSTRUCTIONS }, { role: "user", content: prompt(org, pages) } ])
      response.data.merge("model" => response.model)
    end

    def prompt(org, pages)
      records = Candidate.where(kind: "organization", subject_type: "Organization", subject_id: org.id).order(:id).limit(3)
        .map { |claim| "- #{claim.quote.to_s.squish.first(RECORD_CHARS)}" }
      "Company: #{org.name}\nRole keys: #{Role.order(:key).pluck(:key).join(', ')}\n" \
        "Records that mention it:\n#{records.join("\n").presence || '- none'}\n\n" +
        pages.map { |page| "Page: #{page[:url]}\nTitle: #{page[:title]}\nMain text: #{page[:text]}" }.join("\n\n")
    end

    def reason(answer, why) = "Server pass (#{answer['model']}): #{why}. #{answer['reason'].to_s.squish}".truncate(500)
    def key(org, what) = "dq-pass:research:#{org.id}:#{what}"

    def home(url)
      uri = URI.parse(url.to_s.strip)
      "https://#{uri.host.to_s.downcase}" if uri.host.present?
    rescue URI::Error
      nil
    end

    def finder = @finder ||= DataQuality::Plugins::LeadFinder.new
    def directory = @directory ||= DataQuality::DirectoryClient.new

    # The cheap model for :extract, the strong one for :verify, on the pipeline's key and monthly guard. One
    # attempt each: the daily cap is checked before every paid call, and the client's own retries wouldn't be (Copilot).
    def llm
      @llm ||= begin
        config = DataQuality::Config.from_env
        DataQuality::OpenRouter::Client.new(config: DataQuality::Config.new(api_key: config.api_key,
          extract_model: ENV["DQ_PASS_CHEAP_MODEL"].presence || CHEAP, verify_model: ENV["DQ_PASS_STRONG_MODEL"].presence || STRONG,
          monthly_budget: config.monthly_budget, read_timeout: 60, max_attempts: 1))
      end
    end
end
