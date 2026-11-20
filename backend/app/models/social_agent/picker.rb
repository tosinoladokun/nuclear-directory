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
  NOT_NEWS = /\b(named to|honorees?|under 40|podcast|webinar|workshop|hiring|award ceremony|internship)\b/i

  def initialize(platform:, now: Time.current)
    @platform = platform
    @now = now
  end

  def call = candidates.find { |item| usable?(item) }

  def candidates = news + links + companies

  private
    def news
      NewsItem.published.where(verified_at: (@now - FRESH)..@now, published_on: (@now - EVENT_MAX_AGE).to_date..)
        .includes(:news_mentions).order(verified_at: :desc).filter_map do |news|
          next if [ news.title, news.headline ].compact.any? { |text| text.match?(NOT_NEWS) }
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
        .having("MIN(created_at) BETWEEN ? AND ?", @now - FRESH, @now).select(:subject_id)
      fresh = SocialAgent::Picker.current_links(Relationship.published.where(id: first), @now.to_date)
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
        .having("MIN(created_at) BETWEEN ? AND ?", @now - FRESH, @now).select(:subject_id)
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
