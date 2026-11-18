# Picks the day's item for a platform (#769): something the directory published in the last week (a news deal
# or fact, then a newly added company), never one used on any platform in the last two weeks, nor a company
# already in a post the same day. Social playbook: fresh data only; skip rather than post filler.
class SocialAgent::Picker
  FRESH = 7.days
  # An event older than this isn't news, however recently it was published.
  EVENT_MAX_AGE = 30.days

  def initialize(platform:, now: Time.current)
    @platform = platform
    @now = now
  end

  def call = candidates.find { |item| usable?(item) }

  def candidates = news + companies

  private
    def news
      NewsItem.published.where(verified_at: (@now - FRESH)..@now, published_on: (@now - EVENT_MAX_AGE).to_date..)
        .includes(:news_mentions).order(verified_at: :desc).filter_map do |news|
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

    def companies
      Organization.published.where(verified_at: (@now - FRESH)..@now, created_at: (@now - EVENT_MAX_AGE)..)
        .where.not(description: [ nil, "" ]).order(verified_at: :desc).map do |company|
          evidence = Evidence.where(subject: company).includes(:source).order(:id).first
          SocialAgent::Item.new(subject: company, kind: "new_company",
            facts: { "name" => company.name, "description" => company.description,
                     "headquarters" => [ company.hq_city, company.hq_state ].compact_blank.join(", ") }.compact_blank,
            source_url: evidence&.source&.url, source_quote: evidence&.quote,
            path: "/companies/#{company.slug}", organization_ids: [ company.id ])
        end
    end

    def usable?(item)
      used = SocialPost.used.where(created_at: (@now - SocialPost::COOLDOWN)..)
      return false if used.exists?(subject: item.subject)

      today = @now.in_time_zone(SocialAgent::ZONE).all_day
      used.where(created_at: today).where("organization_ids && ARRAY[?]::bigint[]", item.organization_ids).none?
    end
end
