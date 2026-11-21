# Picks the day's item for a platform (#769): something the directory published in the last week (a news deal
# or fact, a new link between two companies, then a newly added company), never one used on any platform in the last two weeks, nor a company
# already in a post the same day. Social playbook: fresh data only; skip rather than post filler.
class SocialAgent::Picker
  FRESH = 7.days
  # A company with more new links than this in the window approved them in bulk (ARPA-E or DOE award lists):
  # research awards for a roundup, never a "new deal" post (DQ, 20 Nov).
  BULK_LINKS = 3
  # An event older than this isn't news, however recently it was published (DQ: GTM's rule is 7 to 9 days).
  EVENT_MAX_AGE = 10.days
  # Not deals or facts: people and event items (DQ).
  # About the nuclear industry, by its own words (Founder, GTM: a feed can let a pulsar story through).
  NUCLEAR = /\b(nuclear|reactors?|microreactors?|SMRs?|uranium|fission|fusion|isotopes?|radioisotopes?|radioactive|radiation|
    radiological|enrich\w*|HALEU|TRISO|plutonium|thorium|tritium|spent\s+fuel|fuel\s+cycle|NRC|decommission\w*|nuclides?|neutrons?)\b/ix
  NOT_NEWS = /\b(named to|honorees?|under 40|podcast|webinar|webcast|explains?|how [\w-]+(?: [\w-]+){0,3} works|asks why|conference call|earnings call|business update|workshop|hiring|award ceremony|internship)\b/i
  # Link verbs worth a post (DQ, #839): a standing "funds" award row isn't news.
  LINK_VERBS = %w[supplies invests_in offtake_with subsidiary_of].freeze

  # fresh: how far back counts as new (a rehearsal looks back further; social:rehearse).
  # kinds: what the agent posts about (SOCIAL_POST_KINDS, comma-separated; Tosin, 21 Nov, #883: company spotlights are the default and
  # news posts are an occasional extra for later). news, link, new_company and spotlight.
  def self.kinds = ENV.fetch("SOCIAL_POST_KINDS", "spotlight").split(",").map(&:strip).compact_blank
  SPOTLIGHT_COOLDOWN = 8.weeks
  SPOTLIGHT_POOL = 40
  # Not a company to introduce (DQ, 21 Nov): agencies, labs, universities, investors and data-center buyers (these only through their nuclear deals).
  GOVERNMENT_ROLES = %w[government_agency national_lab university research_organization venture_capital data_center_offtaker].freeze
  # Companies whose X/LinkedIn pages GTM verified (SOCIAL_TAGGABLE_SLUGS, comma-separated): picked first so they can be tagged. The directory has no handle field.
  def self.taggable = ENV["SOCIAL_TAGGABLE_SLUGS"].to_s.split(",").map(&:strip).compact_blank

  def initialize(platform:, now: Time.current, fresh: FRESH, kinds: self.class.kinds)
    @kinds = kinds
    @platform = platform
    @now = now
    @fresh = fresh
  end

  def call = candidates.find { |item| usable?(item) }

  # Every usable candidate, best first.
  def usable = candidates.select { |item| usable?(item) }

  def candidates = @kinds.flat_map { |kind| { "spotlight" => :spotlights, "news" => :news, "link" => :links, "new_company" => :companies }.fetch(kind, :none).then { |name| name == :none ? [] : send(name) } }

  private
    def news
      NewsItem.published.where(verified_at: (@now - @fresh)..@now, published_on: (@now - @fresh - (EVENT_MAX_AGE - FRESH)).to_date..)
        .includes(:news_mentions).order(verified_at: :desc).filter_map do |news|
          next if [ news.title, news.headline ].compact.any? { |text| text.match?(NOT_NEWS) }
          next unless [ news.title, news.headline, news.summary ].compact.any? { |text| text.match?(NUCLEAR) }
          # Never one Data Quality said no to, nor one only a feed it flagged off-topic gives (PM, 20 Nov).
          next if rejected_news.include?(news.id) || off_topic?(news)

          mentions = news.news_mentions.select { |mention| mention.subject_type == "Organization" }
          companies = Organization.published.where(id: mentions.map(&:subject_id)).to_a
          next if companies.empty?

          SocialAgent::Item.new(subject: news, kind: "news",
            facts: { "headline" => news.display_title, "summary" => news.summary, "publisher" => news.publisher,
                     "date" => news.published_on.strftime("%-d %B %Y"), "companies" => companies.map(&:name).join(", ") }.compact_blank,
            source_url: news.url, source_quote: [ news.title, news.summary ].compact.join("\n"),
            path: "/companies/#{companies.first.slug}", organization_ids: companies.map(&:id))
        end
    end

    # In effect on the day: started (where it says) and not ended (Copilot; as ConnectionsMap#current).
    def self.current_links(scope, day)
      scope.where("relationships.started_on IS NULL OR relationships.started_on <= ?", day)
        .where("relationships.ended_on IS NULL OR relationships.ended_on > ?", day)
    end

    # A link between two published companies first approved this week, with its own quote and source (PM, 20 Nov:
    # Cameco and Westinghouse weren't news to the picker).
    def links
      first = VerificationEvent.where(subject_type: "Relationship", to_status: "verified").group(:subject_id)
        .having("MIN(created_at) BETWEEN ? AND ?", @now - @fresh, @now).select(:subject_id)
      fresh = SocialAgent::Picker.current_links(Relationship.published.where(id: first, relationship_type: LINK_VERBS), @now.to_date)
      bulk = fresh.group(:from_organization_id).having("COUNT(*) > ?", BULK_LINKS).select(:from_organization_id)
      fresh.where.not(from_organization_id: bulk).includes(:from_organization, :to_organization).order(verified_at: :desc).limit(20).filter_map do |link|
          from, to = link.from_organization, link.to_organization
          verb = DataQuality::Claim::RELATIONSHIP_VERBS.fetch(link.relationship_type, link.relationship_type.humanize(capitalize: false))
          # A quote from a primary source (an older trade-press one would only be blocked; Copilot); none, no item.
          Evidence.where(subject: link).includes(:source).where.not(quote: [ nil, "" ]).order(:id).filter_map do |evidence|
            # Its detail only when this quote states it (Copilot: "49%" must be in the saved quote).
            detail = link.description if link.description.present? &&
              (Array(evidence.fields).include?("description") || evidence.quote.include?(link.description))
            item = SocialAgent::Item.new(subject: link, kind: "link",
              facts: { "link" => "#{from.name} #{verb} #{to.name}", "detail" => detail, "companies" => "#{from.name}, #{to.name}" }.compact_blank,
              source_url: evidence.source&.url, source_quote: evidence.quote, path: "/companies/#{from.slug}", organization_ids: [ from.id, to.id ])
            item if SocialAgent::Rules.primary?(item)
          end.first
        end
    end

    # A new company with a description its own evidence states (Copilot); its headquarters only when a quote backs them.
    def companies
      # New means first approved this week (a later edit re-verifies an old company; DQ), as What's new counts it.
      first = VerificationEvent.where(subject_type: "Organization", to_status: "verified").group(:subject_id)
        .having("MIN(created_at) BETWEEN ? AND ?", @now - @fresh, @now).select(:subject_id)
      Organization.published.where(id: first).where.not(description: [ nil, "" ]).order(verified_at: :desc).filter_map do |company|
        evidence = Evidence.where(subject: company).includes(:source).order(:id).to_a
        described = evidence.find { |row| Array(row.fields).include?("description") || row.quote.to_s.include?(company.description) } or next
        located = evidence.find { |row| (Array(row.fields) & %w[hq_city hq_state]).any? }
        facts = { "name" => company.name, "description" => company.description,
                  "headquarters" => (located && [ company.hq_city, company.hq_state ].compact_blank.join(", ")) }.compact_blank
        SocialAgent::Item.new(subject: company, kind: "new_company", facts:, source_url: described.source&.url,
          source_quote: [ described.quote, located&.quote ].compact.uniq.join("\n"), path: "/companies/#{company.slug}",
          organization_ids: [ company.id ])
      end
    end

    # 'Meet a company' (#883): a published company whose page has a sourced description and website, complete profiles first
    # (a description, headquarters, what it works on and a deal, each sourced), then the most connected, then the newest. Never one
    # spotlighted in the last eight weeks. Its facts are only what the page shows (CompanyProfile) and its source is the company's own site.
    def spotlights
      recent = SocialPost.where.not(status: %w[cancelled blocked failed]).where(subject_type: "Organization", created_at: (@now - SPOTLIGHT_COOLDOWN)..).select(:subject_id)
      # Nothing open on it (DQ): no candidate waiting for review and no pending take-off proposal.
      open = Candidate.where(subject_type: "Organization", status: %w[new matched needs_review]).select(:subject_id)
      proposed = TakeoffProposal.where(subject_type: "Organization", status: "pending").select(:subject_id)
      pool = Organization.published.where.not(description: [ nil, "" ]).where.not(website: [ nil, "" ]).where.not(id: recent).where.not(id: open).where.not(id: proposed).to_a
      return [] if pool.empty?

      links = Relationship.published.where(from_organization_id: pool.map(&:id)).group(:from_organization_id).count
        .merge(Relationship.published.where(to_organization_id: pool.map(&:id)).group(:to_organization_id).count) { |_, from, to| from + to }
      pool.sort_by { |company| [ -links.fetch(company.id, 0), -company.verified_at.to_i ] }.first(SPOTLIGHT_POOL)
        .filter_map { |company| spotlight(company) }.each_with_index.sort_by { |item, index| [ self.class.taggable.include?(item.subject.slug) ? 0 : 1, index ] }.map(&:first)
    end

    def spotlight(company)
      profile = CompanyProfile.new(company)
      return unless profile.sourced? && profile.description.present? && profile.website.present?
      # A company, not an agency, lab or university ('Meet a company', #883).
      return if profile.roles.empty? || profile.roles.all? { |row| GOVERNMENT_ROLES.include?(row.role.key) }

      evidence = company.evidence.includes(:source).order(:id).to_a
      described = evidence.find { |row| Array(row.fields).include?("description") || row.quote.to_s.include?(company.description) } or return
      located = evidence.find { |row| (Array(row.fields) & %w[hq_city hq_state]).any? }
      works_on = (profile.shown_roles.map { |row| row.role.name } + profile.technologies.map { |row| row.technology.name }).uniq.first(4)
      deals = profile.deals.select { |deal| SocialAgent::Picker.current_links(Relationship.where(id: deal.id), @now.to_date).exists? }.first(3).map do |deal|
        verb = DataQuality::Claim::RELATIONSHIP_VERBS.fetch(deal.relationship_type, deal.relationship_type.humanize(capitalize: false))
        "#{deal.from_organization.name} #{verb} #{deal.to_organization.name}"
      end
      headquarters = [ company.hq_city, company.hq_state ].compact_blank.join(", ") if located
      facts = { "name" => company.name, "description" => company.description, "headquarters" => headquarters.presence,
                "works on" => works_on.to_sentence.presence, "relationships" => deals.join("; ").presence,
                "founded" => company.founded_year&.to_s }.compact_blank
      # The page its description rests on when that is the company's own site (a redirect on the bare homepage doesn't stop it), else the site.
      own = described.source&.url.presence if described.source&.url.present? && SocialAgent::Rules.primary?(SocialAgent::Item.new(subject: company, kind: "spotlight", facts: {}, source_url: described.source.url, source_quote: nil, path: nil, organization_ids: [ company.id ]))
      item = SocialAgent::Item.new(subject: company, kind: "spotlight", facts:, source_url: own || company.website,
        source_quote: [ described.quote, located&.quote ].compact.uniq.join("\n"), path: "/companies/#{company.slug}", organization_ids: [ company.id ])
      # Complete only (DQ): a role, a website, a description, a sourced headquarters and at least one current link to a published company.
      item if headquarters.present? && deals.any?
    end

    def rejected_news
      @rejected_news ||= Candidate.where(subject_type: "NewsItem", dq_recommendation: "reject").distinct.pluck(:subject_id).to_set
    end

    # Feeds Data Quality flags as off-topic, by source kind (SOCIAL_SKIP_FEEDS, comma-separated on Render).
    def off_topic?(news)
      feeds = ENV["SOCIAL_SKIP_FEEDS"].to_s.split(",").map(&:strip).compact_blank
      return false if feeds.empty?

      kinds = (Evidence.where(subject: news).joins(:source).distinct.pluck("sources.source_kind") +
        Candidate.where(subject_type: "NewsItem", subject_id: news.id).joins(:source).distinct.pluck("sources.source_kind")).uniq
      kinds.any? && (kinds - feeds).empty?
    end

    def usable?(item)
      # Any attempt in the cooldown, even blocked or failed, so a rerun can never send it twice (Infra); a post the
      # switch took back frees its item.
      used = SocialPost.where.not(status: "cancelled").where(created_at: (@now - SocialPost::COOLDOWN)..)
      return false if used.exists?(subject: item.subject)

      today = @now.in_time_zone(SocialAgent::ZONE).all_day
      used.where(created_at: today).where("organization_ids && ARRAY[?]::bigint[]", item.organization_ids).none?
    end
end
