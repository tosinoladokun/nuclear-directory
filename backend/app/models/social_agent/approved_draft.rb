# A text the graders approved (#896), turned into a drafted SocialPost for Admin > Posts. It checks what a person can't be trusted to retype
# (the hash, our page's own tracked link, the platform's limits, the one-send and cooldown rules) and refuses on any of those; the agent's
# content checks run too, and what they find about the company page's own words (a number or name the page doesn't carry, a qualifier) is
# returned as warnings, because the graders checked a hand-approved text against its primary sources. It never sends.
class SocialAgent::ApprovedDraft
  Result = Data.define(:post, :errors, :warnings, :codes) do
    def initialize(post:, errors:, warnings:, codes: [])
      super
    end
  end
  GRADERS = %w[GTM Founder DQ].freeze
  # What stays a refusal whatever the page says: the text's own shape. A test feeds each shape to the real checks, so a reworded check
  # can't quietly become a warning (Infra).
  HARD = /own link|hashtag|emoji|too long|empty or a placeholder/
  # Stable codes for what is refused (the messages may be reworded).
  CODES = %w[platform text_empty graders company dq_approval link sha256 url_in_text already_sent cooldown send_on_taken hard_check send_on length annotations card content_sha opener_repeat].freeze
  X_WEIGHT = 280
  X_URL_WEIGHT = 23
  OPENER_RECENT = 5

  # The text's own hard problems (shape only), for the creation check and again at send (SocialAgent.recheck).
  def self.hard_problems(text, platform)
    item = SocialAgent::Item.new(subject: nil, kind: "spotlight", facts: {}, source_url: nil, source_quote: nil, path: nil, organization_ids: [])
    SocialAgent::Check.problems(text, item, platform:).grep(HARD)
  end

  def self.call(**args) = new(**args).call
  class << self
    attr_writer :fetcher
    def fetcher = @fetcher ||= DataQuality::Fetcher.new
  end

  def initialize(platform:, slug:, text:, link:, sha256:, graders:, source_url: nil, send_on: nil, annotations: nil, card: nil, content_payload_sha256: nil,
                 opener_pattern_id: nil, now: Time.current, fetcher: nil)
    @platform, @slug, @text, @link, @sha, @graders, @source_url, @now = platform, slug, text.to_s.strip, link, sha256.to_s.downcase, graders, source_url, now
    @send_on = send_on
    @annotations, @card, @content_sha, @opener = annotations, card, content_payload_sha256.to_s.downcase.presence, opener_pattern_id.to_s.strip.presence
    @fetcher = fetcher
  end

  def call
    errors = []
    err = ->(code, message) { errors << [ code, message ] }
    err.("platform", "platform must be x or linkedin") unless SocialChannel::PLATFORMS.include?(@platform)
    err.("text_empty", "the text is empty") if @text.blank?
    named = @graders.map { |name| name.to_s.strip.downcase }
    err.("graders", "graders must name GTM, Founder and DQ (all three passed it)") unless GRADERS.all? { |name| named.include?(name.downcase) }
    send_on = parse_send_on(err)
    company = Organization.published.find_by(slug: @slug)
    err.("company", "no published company #{@slug.inspect}") unless company
    return result(nil, errors, []) if errors.any?

    expected = "#{SocialAgent::SITE}/companies/#{company.slug}?utm_source=#{@platform}&utm_medium=social&utm_campaign=#{company.slug}"
    err.("link", "the link must be #{expected}") unless @link == expected
    # X may carry our own company URL inside the text (then a handle after it): the text is stored and SENT VERBATIM, and its hash is the text's own.
    exact = @platform == "x" && @text.scan(%r{https?://\S+}i) == [ @link ]
    shapes = exact ? [ @text ] : [ @text, "#{@text}\n\n#{@link}" ]
    err.("sha256", "sha256 matches neither the text nor the text + blank line + link") unless shapes.map { |shape| Digest::SHA256.hexdigest(shape) }.include?(@sha)
    err.("url_in_text", "the text carries a URL other than our own link (on X, our link exactly once; on LinkedIn none: the card carries it)") if !exact && @text.match?(%r{https?://}i)
    err.("url_in_text", "the text carries a second URL") if exact && @text.scan(%r{https?://\S+}i).size > 1
    err.("length", "over X's 280 weighted characters (the URL counts as 23): #{x_weight(@text)}") if exact && x_weight(@text) > X_WEIGHT
    card, annotations = validate_native(err)
    err.("opener_repeat", "that opener pattern was used in the last #{OPENER_RECENT} posts on #{@platform}") if @opener && opener_recent(@opener)
    # Data Quality's recorded PASS of exactly this hash (POST /api/dq/social_approvals): "graders: DQ" is a fact on file, not the caller's word.
    err.("dq_approval", "Data Quality has not recorded a PASS for this exact sha256 (POST /api/dq/social_approvals)") unless ::SocialApproval.exists?(platform: @platform, slug: @slug, sha256: @sha)
    used_by_another(company, send_on).each { |code, message| err.(code, message) }
    problems = problems_for(company, exact)
    hard, warnings = problems.partition { |problem| problem.match?(HARD) }
    hard.each { |problem| err.("hard_check", problem) }
    return result(nil, errors, warnings) if errors.any?

    # Created under the platform's channel lock with the conflicts read again, so two overlapping submissions for the same company can't both
    # be created (each would then block the other's send; Copilot).
    post = nil
    again = []
    SocialChannel.transaction do
      SocialChannel.for(@platform).lock!
      again = used_by_another(company, send_on)
      next if again.any?

      post = SocialPost.create!(platform: @platform, status: "drafted", subject: company, text: @text, link: @link, source_url: @source_url.presence || company.website,
        organization_ids: [ company.id ], reason: "#{SocialPost::GRADED} #{@graders.join(', ')}", send_on:, warnings: warnings.presence&.join("\n"), approved_sha256: @sha, exact_text: exact, card:, annotations:, content_payload_sha256: @content_sha, opener_pattern_id: @opener, created_at: @now)
    end
    return result(nil, again, warnings) if again.any?

    result(post, [], warnings)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    result(nil, [ [ "hard_check", "couldn't save the draft: #{error.message}" ] ], [])
  end

  # The LinkedIn card and native mentions the graders approved, checked as a set: every annotation names the same Page in its id, urn, link and vanity name and
  # the name stands in the text where it says; the canonical JSON hash of the whole content payload is the one on file with Data Quality.
  def validate_native(err)
    return [ nil, nil ] if @platform != "linkedin"

    # A LinkedIn post always carries its card and the content hash DQ approved (no page-read, unhashed card; DQ): mentions may be none.
    card = @card.to_h.stringify_keys.slice("title", "description", "image_url")
    err.("card", "a LinkedIn post needs its card: a title, a description and an image_url") unless card.values_at("title", "description", "image_url").all?(&:present?)
    annotations = Array(@annotations).map { |annotation| annotation.to_h.stringify_keys.slice("id", "entity", "start", "length", "link", "localizedName", "vanityName") }
    annotations.each do |annotation|
      name = annotation["localizedName"].to_s
      ok = annotation["id"].to_s.match?(/\A\d+\z/) && annotation["entity"] == "urn:li:organization:#{annotation['id']}" &&
        annotation["link"] == "https://www.linkedin.com/company/#{annotation['vanityName']}" && annotation["vanityName"].to_s.present? &&
        annotation["start"].is_a?(Integer) && annotation["length"] == name.length && @text[annotation["start"], name.length] == name
      err.("annotations", "annotation for #{name.inspect} doesn't match its id, urn, link, vanity name or its place in the text") unless ok
    end
    expected = self.class.content_hash(text: @text, link: @link, annotations:, card:)
    err.("content_sha", "content_payload_sha256 doesn't match the canonical JSON of the text, annotations and card") unless @content_sha == expected
    err.("dq_approval", "Data Quality has not recorded a PASS for the content_payload_sha256") unless @content_sha && ::SocialApproval.exists?(platform: @platform, slug: @slug, sha256: @content_sha)
    [ card.presence, annotations.presence ]
  end

  # {text, metadata: {linkedin: {annotations, linkAttachment: {url, title, description, thumbnail: {url}}}}}: sorted keys, compact, unescaped unicode.
  # A class method: computed again at send from the stored row (SocialAgent.recheck).
  def self.content_hash(text:, link:, annotations:, card:)
    card = card.to_h.stringify_keys
    payload = { "text" => text, "metadata" => { "linkedin" => { "annotations" => Array(annotations), "linkAttachment" => { "url" => link, "title" => card["title"],
      "description" => card["description"], "thumbnail" => { "url" => card["image_url"] } } } } }
    Digest::SHA256.hexdigest(JSON.generate(canonical(payload)))
  end

  def self.canonical(value)
    case value
    when Hash then value.sort_by { |key, _| key.to_s }.to_h { |key, inner| [ key.to_s, canonical(inner) ] }
    when Array then value.map { |inner| canonical(inner) }
    else value
    end
  end

  # X's weight: each of our URLs counts 23, every other character 1 (ASCII text; GTM's weighted_length rule).
  def x_weight(text) = text.gsub(%r{https?://\S+}, "x" * X_URL_WEIGHT).length

  def opener_recent(id)
    SocialPost.where(platform: @platform).where.not(opener_pattern_id: nil).where.not(status: %w[cancelled blocked failed]).order(id: :desc).limit(OPENER_RECENT).pluck(:opener_pattern_id).include?(id)
  end

  private
    def result(post, errors, warnings) = Result.new(post:, errors: errors.map(&:last).uniq, warnings:, codes: errors.map(&:first).uniq)

    def parse_send_on(err)
      return if @send_on.blank?

      date = Date.iso8601(@send_on.to_s)
      err.("send_on", "send_on must be today or later, on a weekday") if date < @now.in_time_zone(SocialAgent::ZONE).to_date || date.on_weekend?
      # The agent doesn't post on a federal holiday (Thanksgiving, 26 Nov): a row for one would only wait, so it isn't accepted; load the next weekday.
      err.("send_on", "#{date} is a holiday: nothing is sent that day, pick another weekday") if SocialAgent::Rules.holiday?(date)
      date
    rescue Date::Error
      err.("send_on", "send_on must be a date (YYYY-MM-DD)")
      nil
    end

    # One send ever per company and platform; one approved row per platform per day; and 14 days between a company's posts on a platform
    # counted around the day this one goes out (a row waiting for its day counts on that day, not on the day it was loaded).
    def used_by_another(company, send_on)
      sent = SocialPost.where(subject: company, platform: @platform, status: SocialPost::SENT)
      return [ [ "already_sent", "this platform already sent a post about #{company.name} (one send per company and platform)" ] ] if sent.exists?

      target = send_on || @now.in_time_zone(SocialAgent::ZONE).to_date
      found = []
      if send_on && SocialPost.waiting.where(platform: @platform, send_on:).exists?
        found << [ "send_on_taken", "an approved post for #{@platform} is already queued for #{send_on} (one per platform per day)" ]
      end
      near = SocialPost.where(subject: company, platform: @platform).where.not(status: %w[cancelled blocked failed]).detect do |post|
        ((post.send_on || post.created_at.in_time_zone(SocialAgent::ZONE).to_date) - target).abs < SocialPost::COOLDOWN.in_days
      end
      found << [ "cooldown", "a post about #{company.name} already exists on this platform (post #{near.id}, #{near.status}) within #{SocialPost::COOLDOWN.inspect} of #{target}" ] if near
      found
    end

    # The agent's own content checks against what our page for the company says (and its source page when given).
    def problems_for(company, exact = false)
      profile = CompanyProfile.new(company)
      deals = profile.deals.map { |deal| [ deal.from_organization.name, "and", deal.to_organization.name, deal.description ].compact.join(" ") }
      facts = { "name" => company.name, "description" => profile.description, "headquarters" => [ profile.hq_city, profile.hq_state ].compact_blank.join(", "), "records" => deals.join("; ") }.compact_blank
      item = SocialAgent::Item.new(subject: company, kind: "spotlight", facts:, source_url: @source_url.presence || company.website, source_quote: facts.values.join("\n"),
        path: "/companies/#{company.slug}", organization_ids: [ company.id ])
      fetcher = @fetcher || self.class.fetcher
      ready, pre = SocialAgent.prepare(item, fetcher)
      found = pre.map { |problem| "source: #{problem}" }
      # The checks read the post's prose: with our URL inside an exact X text, they read it without the URL (its length is checked separately).
      prose = exact ? @text.sub(@link, "").squeeze("\n").strip : @text
      found.concat(SocialAgent::Check.problems(prose, ready, platform: @platform).reject { |problem| exact && problem.match?(/too long/) })
      found.concat(SocialAgent::Rules.problems(prose, ready, platform: @platform, fetcher:)) if found.none? { |problem| problem.match?(HARD) }
      found
    rescue StandardError => error
      [ "the content checks couldn't run (#{error.class})" ]
    end
end
