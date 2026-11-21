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
  # Words that mean the nuclear industry on their own. "Radiation", "isotope", "neutron" and the like are left out: a space-radiation or
  # medical-imaging story uses them without being about the industry (NASA bone-marrow chip, news 55, 21 Nov).
  NUCLEAR = /\b(nuclear|reactors?|microreactors?|SMRs?|uranium|fission|fusion\s+(?:energy|power|reactors?|plants?|company|startup)|radioisotopes?|radioactive\s+(?:waste|material)s?|
    HALEU|TRISO|plutonium|thorium|tritium|spent\s+fuel|fuel\s+cycle|NRC|nuclides?)\b/ix
  NOT_NEWS = /\b(named to|honorees?|under 40|podcast|webinar|webcast|explains?|how [\w-]+(?: [\w-]+){0,3} works|asks why|conference call|earnings call|business update|workshop|hiring|award ceremony|internship)\b/i
  # Link verbs worth a post (DQ, #839): a standing "funds" award row isn't news.
  LINK_VERBS = %w[supplies invests_in offtake_with subsidiary_of].freeze

  # fresh: how far back counts as new (a rehearsal looks back further; social:rehearse).
  # kinds: what the agent posts about (SOCIAL_POST_KINDS, comma-separated; Tosin, 21 Nov, #883: company spotlights are the default and
  # news posts are an occasional extra for later). news, link, new_company and spotlight.
  def self.kinds = ENV.fetch("SOCIAL_POST_KINDS", "spotlight").split(",").map(&:strip).compact_blank
  ALL_KINDS = %w[news link new_company spotlight].freeze
  SPOTLIGHT_COOLDOWN = 8.weeks
  SPOTLIGHT_POOL = 40
  # Not a company to introduce (DQ, 21 Nov): agencies, labs, universities, investors and data-center buyers (these only through their nuclear deals).
  GOVERNMENT_ROLES = %w[government_agency national_lab university research_organization venture_capital data_center_offtaker].freeze
  # Companies whose X/LinkedIn accounts GTM verified (config/social_tags.yml): picked first, and on X tagged with their handle.
  def self.tags = @tags ||= YAML.safe_load_file(Rails.root.join("config/social_tags.yml")) || {}
  def self.taggable = tags.keys

  def initialize(platform:, now: Time.current, fresh: FRESH, kinds: self.class.kinds, except: nil)
    @kinds = kinds
    @except = except
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
      recent = SocialPost.where.not(id: @except).where.not(status: %w[cancelled blocked failed]).where(subject_type: "Organization", created_at: (@now - SPOTLIGHT_COOLDOWN)..).select(:subject_id)
      # And never one this platform already sent (any age): the one-send index (index_social_posts_one_send) would refuse its second send, so a
      # repeat after eight weeks needs its own send identity first (tracked: #895).
      sent = SocialPost.where.not(id: @except).where(subject_type: "Organization", platform: @platform, status: SocialPost::SENT).select(:subject_id)
      # Nothing open on it (DQ): no candidate waiting for review and no pending take-off proposal.
      open = Candidate.where(subject_type: "Organization", status: %w[new matched needs_review]).select(:subject_id)
      proposed = TakeoffProposal.where(subject_type: "Organization", status: "pending").select(:subject_id)
      pool = Organization.published.where.not(description: [ nil, "" ]).where.not(website: [ nil, "" ]).where.not(id: recent).where.not(id: sent).where.not(id: open).where.not(id: proposed).to_a
      return [] if pool.empty?

      links = Relationship.published.where(from_organization_id: pool.map(&:id)).group(:from_organization_id).count
        .merge(Relationship.published.where(to_organization_id: pool.map(&:id)).group(:to_organization_id).count) { |_, from, to| from + to }
      # Verified-account companies first, then the most connected, then the newest; the limit counts ELIGIBLE spotlights, so a thin profile
      # above a complete one never hides it (Copilot).
      ordered = pool.sort_by { |company| [ self.class.taggable.include?(company.slug) ? 0 : 1, -links.fetch(company.id, 0), -company.verified_at.to_i ] }
      items = []
      ordered.each do |company|
        break if items.size >= SPOTLIGHT_POOL

        item = spotlight(company)
        items << item if item
      end
      items
    end

    def spotlight(company)
      profile = CompanyProfile.new(company)
      return unless profile.sourced? && profile.description.present? && profile.website.present?
      # A company, not an agency, lab or university ('Meet a company', #883).
      return if profile.roles.empty? || profile.roles.all? { |row| GOVERNMENT_ROLES.include?(row.role.key) }

      evidence = company.evidence.includes(:source).order(:id).to_a
      described = evidence.find { |row| Array(row.fields).include?("description") || row.quote.to_s.include?(company.description) } or return
      located = evidence.find { |row| Directory::QuoteBacking.place?([ row.quote ], city: company.hq_city, state: company.hq_state) }
      # Each link in its own words (DQ, #884): the record's description at its strength (an announced plan stays a plan, a loan a loan), its
      # date and where it comes from, never a bare verb; a link with no description of its own isn't told. No "works on" line: roles and
      # technologies aren't quotes from the company.
      # A "supplies" link whose description doesn't speak of supply, fuel or services isn't a supply link (DQ: Dominion and CFS is a lease).
      supply = /suppl|fuel|service|provid|deliver|procure|offtak|purchase/i
      told = profile.deals.select { |deal| SocialAgent::Picker.current_links(Relationship.where(id: deal.id), @now.to_date).exists? && deal.description.present? &&
        # An undated link isn't told (DQ: "ARPA-E research funding" with no year reads as a present state).
        (profile.deal_date(deal) || deal.description.match?(/\b(?:19|20)\d{2}\b/)) &&
        (deal.relationship_type != "supplies" || deal.description.match?(supply)) }.first(@platform == "x" ? 1 : 2)
      deals = told.map do |deal|
        date = profile.deal_date(deal)&.strftime("%B %Y")
        from = deal.evidence.filter_map { |row| row.source&.url }.first
        stage = " [stage: #{deal.stage_label.downcase}]" if deal.stage
        "#{deal.from_organization.name} and #{deal.to_organization.name}: #{deal.description.squish.delete_suffix('.')}#{" (#{date})" if date}#{stage}#{" [source: #{source_label(from, company)}]" if from}"
      end
      headquarters = [ company.hq_city, company.hq_state ].compact_blank.join(", ") if located
      facts = { "name" => company.name, "description" => company.description, "description comes from" => source_label(described.source&.url, company),
                "headquarters" => headquarters.presence, "headquarters comes from" => (source_label(located.source&.url, company) if located),
                "records of its links" => deals.join("; ").presence,
                "x_handle" => (self.class.tags.dig(company.slug, "x") if @platform == "x") }.compact_blank
      # The page its description rests on when that is the company's own site (a redirect on the bare homepage doesn't stop it), else the site.
      own = described.source.url if described.source&.url.present? && source_label(described.source.url, company) == "the company's own website"
      item = SocialAgent::Item.new(subject: company, kind: "spotlight", facts:, source_url: own || company.website,
        source_quote: [ described.quote, located&.quote ].compact.uniq.join("\n"), path: "/companies/#{company.slug}", organization_ids: [ company.id, *told.flat_map { |deal| [ deal.from_organization_id, deal.to_organization_id ] } ].uniq)
      # Complete only (DQ): a role, a website, a description, a sourced headquarters and at least one current link to a published company.
      item if headquarters.present? && deals.any?
    end

    # Where a fact really comes from, in words: the company's own website only when it is, else the page's site (DQ: never "its website" for a DOE or SEC page).
    def source_label(url, company)
      host = SocialAgent::Rules.host(url).to_s.delete_prefix("www.")
      return "an unnamed page" if host.blank?

      own = [ company.domain, company.website ].compact.map { |site| (site.include?("/") ? SocialAgent::Rules.host(site) : site).to_s.delete_prefix("www.") }.reject(&:blank?)
      own.any? { |site| host == site || host.end_with?(".#{site}") } ? "the company's own website" : "a page on #{host}"
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
