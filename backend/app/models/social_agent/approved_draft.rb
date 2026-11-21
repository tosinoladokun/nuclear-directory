# A text the graders approved (#896), turned into a drafted SocialPost for Admin > Posts. It checks what a person can't be trusted to retype
# (the hash, our page's own tracked link, the platform's limits, the one-send and cooldown rules) and refuses on any of those; the agent's
# content checks run too, and what they find about the company page's own words (a number or name the page doesn't carry, a qualifier) is
# returned as warnings, because the graders checked a hand-approved text against its primary sources. It never sends.
class SocialAgent::ApprovedDraft
  Result = Data.define(:post, :errors, :warnings)
  GRADERS = %w[GTM Founder DQ].freeze
  # What stays a refusal whatever the page says: the text's own shape.
  HARD = /own link|hashtag|emoji|too long|empty or a placeholder/

  def self.call(**args) = new(**args).call
  class << self
    attr_writer :fetcher
    def fetcher = @fetcher ||= DataQuality::Fetcher.new
  end

  def initialize(platform:, slug:, text:, link:, sha256:, graders:, source_url: nil, now: Time.current, fetcher: nil)
    @platform, @slug, @text, @link, @sha, @graders, @source_url, @now = platform, slug, text.to_s.strip, link, sha256.to_s.downcase, graders, source_url, now
    @fetcher = fetcher
  end

  def call
    errors = []
    errors << "platform must be x or linkedin" unless SocialChannel::PLATFORMS.include?(@platform)
    errors << "the text is empty" if @text.blank?
    named = @graders.map { |name| name.to_s.strip.downcase }
    errors << "graders must name GTM, Founder and DQ (all three passed it)" unless GRADERS.all? { |name| named.include?(name.downcase) }
    company = Organization.published.find_by(slug: @slug)
    errors << "no published company #{@slug.inspect}" unless company
    return Result.new(nil, errors, []) if errors.any?

    expected = "#{SocialAgent::SITE}/companies/#{company.slug}?utm_source=#{@platform}&utm_medium=social&utm_campaign=#{company.slug}"
    errors << "the link must be #{expected}" unless @link == expected
    errors << "sha256 matches neither the text nor the text + blank line + link" unless [ @text, "#{@text}\n\n#{@link}" ].map { |shape| Digest::SHA256.hexdigest(shape) }.include?(@sha)
    errors << "the text carries a URL: the link is added when it is sent" if @text.match?(%r{https?://}i)
    errors.concat(used_by_another(company))
    problems = problems_for(company)
    hard, warnings = problems.partition { |problem| problem.match?(HARD) }
    errors.concat(hard)
    return Result.new(nil, errors.uniq, warnings) if errors.any?

    post = SocialPost.create!(platform: @platform, status: "drafted", subject: company, text: @text, link: @link, source_url: @source_url.presence || company.website,
      organization_ids: [ company.id ], reason: "#{SocialPost::GRADED} #{@graders.join(', ')}", created_at: @now)
    Result.new(post, [], warnings)
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
    Result.new(nil, [ "couldn't save the draft: #{error.message}" ], [])
  end

  private
    def used_by_another(company)
      sent = SocialPost.where(subject: company, platform: @platform, status: SocialPost::SENT)
      return [ "this platform already sent a post about #{company.name} (one send per company and platform)" ] if sent.exists?

      open = SocialPost.where(subject: company, platform: @platform).where.not(status: %w[cancelled blocked failed]).where(created_at: (@now - SocialPost::COOLDOWN)..)
      open.exists? ? [ "a post about #{company.name} already exists on this platform (post #{open.first.id}, #{open.first.status}) within #{SocialPost::COOLDOWN.inspect}" ] : []
    end

    # The agent's own content checks against what our page for the company says (and its source page when given).
    def problems_for(company)
      profile = CompanyProfile.new(company)
      deals = profile.deals.map { |deal| [ deal.from_organization.name, "and", deal.to_organization.name, deal.description ].compact.join(" ") }
      facts = { "name" => company.name, "description" => profile.description, "headquarters" => [ profile.hq_city, profile.hq_state ].compact_blank.join(", "), "records" => deals.join("; ") }.compact_blank
      item = SocialAgent::Item.new(subject: company, kind: "spotlight", facts:, source_url: @source_url.presence || company.website, source_quote: facts.values.join("\n"),
        path: "/companies/#{company.slug}", organization_ids: [ company.id ])
      fetcher = @fetcher || self.class.fetcher
      ready, pre = SocialAgent.prepare(item, fetcher)
      found = pre.map { |problem| "source: #{problem}" }
      found.concat(SocialAgent::Check.problems(@text, ready, platform: @platform))
      found.concat(SocialAgent::Rules.problems(@text, ready, platform: @platform, fetcher:)) if found.none? { |problem| problem.match?(HARD) }
      found
    rescue StandardError => error
      [ "the content checks couldn't run (#{error.class})" ]
    end
end
