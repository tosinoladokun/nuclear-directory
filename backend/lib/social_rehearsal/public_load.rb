# Loads the directory's own public updates (/updates.atom) into an empty local database, so social:rehearse runs on
# real items without a backup (Tosin, 20 Nov: public data only, a fresh database each round). Local use only.
#
# - news: a published NewsItem with its title and source; its date and publisher read from the source page; linked
#   to the company its entry points at.
# - fact "<A> invests in <B>" (a link): a published Relationship approved at the entry's time, its detail from the
#   entry, its quote the source page's sentence naming both companies (none found: skipped).
# Companies are created published by name (from their public page's title). New-company entries are skipped: their
# descriptions' quotes aren't public.
module SocialRehearsal
  class PublicLoad
    BY = "human:rehearsal".freeze
    FEED = "https://nuclear-directory.org/updates.atom".freeze
    SITE = "https://nuclear-directory.org".freeze
    INDEX = "#{SITE}/search/index.json".freeze
    # Public pages kept a day on this Mac, so rounds don't fetch the live site again.
    CACHE = Rails.root.join("tmp/rehearsal/cache")
    VERBS = DataQuality::Claim::RELATIONSHIP_VERBS.invert

    Loaded = Data.define(:news, :links, :skipped)

    def initialize(fetcher: DataQuality::Fetcher.new(sleeper: ->(_) { }), feed: FEED, companies: true)
      @fetcher = fetcher
      @feed = feed
      @companies = companies
    end

    def call
      doc = Nokogiri::XML(get(@feed).to_s).remove_namespaces!
      news = links = 0
      skipped = []
      # The directory's own dates first (each company's Latest list shows the published date, as production has it); the source
      # page's date only for what no company page lists (PM, 20 Nov: INL's supercomputer is 18 Nov, not the page's 27 Oct).
      news += load_company_news if @companies
      doc.xpath("//entry").each do |entry|
        kind = entry.at_xpath("category")&.[]("term")
        title = entry.at_xpath("title")&.text.to_s.squish
        page = entry.at_xpath("link[@rel='alternate']")&.[]("href").to_s
        source = entry.at_xpath("link[@rel='related']")&.[]("href").to_s
        at = Time.zone.parse(entry.at_xpath("updated")&.text.to_s)
        summary = entry.at_xpath("summary")&.text.to_s.sub(/\s*Source:.*\z/m, "").squish.presence
        case kind
        when "news" then load_news(title, page, source, at) ? news += 1 : skipped << title
        when "fact"
          next unless VERBS.keys.any? { |verb| title.include?(" #{verb} ") }

          load_link(title, page, source, at, summary) ? links += 1 : skipped << title
        end
      rescue StandardError => error
        skipped << "#{title} (#{error.class})"
      end
      Loaded.new(news:, links:, skipped:)
    end

    # Each company page's Latest list: its news items as the directory published them (title, date, source).
    def load_company_news
      items = JSON.parse(get(INDEX).to_s)["items"].select { |item| item["k"] == "c" }
      items.sum do |item|
        page = "#{SITE}/companies/#{item['s']}"
        html = get(page).to_s
        Nokogiri::HTML(html).css("li.nd-news").count do |row|
          url = row.at_css("a.nd-news__src")&.[]("href").to_s
          date = (Date.iso8601(row.at_css("time")&.[]("datetime").to_s) rescue nil)
          title = row.at_css(".nd-news__title")&.text.to_s.squish
          next false if url.blank? || date.nil? || title.blank? || NewsItem.exists?(url:)

          org = company(page) or next false
          news = NewsItem.create!(url:, title:, publisher: org.name, published_on: date, verification_status: "verified", verified_by: BY,
            verified_at: date.in_time_zone.change(hour: 18))
          NewsMention.create!(news_item: news, subject: org)
          true
        end
      rescue StandardError
        0
      end
    end

    # 'Meet a company' (#883): up to `limit` company pages as the directory publishes them: its one-line description, headquarters,
    # website, what it works on (tags) and its deals with their own quotes and sources. Public data only, like the news above.
    # Only companies that show a description, a website and at least one deal; spread across the index, not just the first ones.
    def load_spotlights(limit = 20, slugs: [])
      items = JSON.parse(get(INDEX).to_s)["items"].select { |item| item["k"] == "c" }
      loaded = 0
      # A spread across the index first (every 5th), then the rest, until `limit` pages have what a spotlight needs.
      # slugs: these companies first, in this order (GTM's priority accounts).
      named = slugs.filter_map { |slug| items.find { |item| item["s"] == slug } }
      ordered = named + items.each_slice(5).map(&:first) + items.each_with_index.reject { |_, index| (index % 5).zero? }.map(&:first)
      ordered.each do |item|
        break if loaded >= limit

        loaded += 1 if load_spotlight("#{SITE}/companies/#{item['s']}")
      rescue StandardError => error
        warn "spotlight #{item['s']}: #{error.class}: #{error.message.to_s.first(100)}"
      end
      loaded
    end

    private
      def load_spotlight(page)
        doc = Nokogiri::HTML(get(page).to_s)
        name = doc.at_css("h1.nd-pagehead__name")&.[]("title").to_s.squish.presence or return false
        about = doc.at_css(".nd-pagehead__about")&.text.to_s.squish.presence or return false
        site = doc.at_css("a[data-outbound='company_website']")&.[]("href").to_s.sub(/\?.*\z/, "").presence or return false
        hq = doc.css(".nd-glance__fact").find { |fact| fact.at_css("dt")&.text == "Headquarters" }&.at_css("dd")&.text.to_s.squish
        city, state = hq.to_s.split(", ", 2)
        rows = doc.css("li.nd-crow").filter_map do |row|
          who = row.at_css(".nd-crow__who")&.[]("title").to_s.squish
          verb = VERBS.keys.find { |word| who.include?(" #{word} ") } or next
          left, right = who.split(" #{verb} ", 2)
          quote = row.at_css(".nd-quote")&.text.to_s.gsub(/[“”]/, "").squish.presence
          url = row.at_css("a.nd-src")&.[]("href").to_s.presence
          detail = row.at_css("p.type-body")&.text.to_s.squish.presence
          type = VERBS.fetch(verb)
          type = "offtake_with" if type == "offtakes_from"
          [ left, type, right, quote, url, detail ] if quote && url && detail && (left == name || right == name) && Relationship.relationship_types.key?(type)
        end
        return false if rows.empty?

        slug = page[%r{/companies/([a-z0-9-]+)}, 1]
        existing = Organization.find_by(slug:)
        return false if existing&.description.present?

        attrs = { website: site, domain: URI(site).host.to_s.delete_prefix("www."), description: about, hq_city: city, hq_state: state }
        org = existing ? existing.tap { |row| row.update!(attrs) } : Organization.create!(name: CGI.unescapeHTML(name), slug:, verification_status: "verified", verified_by: BY, verified_at: 30.days.ago, **attrs)
        site_source = Source.find_or_create_by!(url: site) { |row| row.source_kind = "web_page"; row.crawl_status = "ok" }
        Evidence.create!(subject: org, source: site_source, quote: about, found_by: "human", fields: %w[description])
        # The public page is the only place the rehearsal finds the headquarters: the directory's own record, not the company's website (Founder, round 13).
        Evidence.create!(subject: org, source: Source.find_or_create_by!(url: page) { |row| row.source_kind = "web_page"; row.crawl_status = "ok" }, quote: hq, found_by: "human", fields: %w[hq_city hq_state]) if hq.present?
        # The page's own role tag (its first tag, e.g. "Reactor designer"); the Government and research bucket is the agency role, so the
        # picker can tell an agency from a company.
        role_label = doc.at_css(".nd-pagehead__tags span.nd-tag")&.text.to_s.squish.presence
        if role_label
          key = doc.at_css(".nd-pagehead__tags .nd-bucket--government-research") ? "government_agency" : role_label.parameterize(separator: "_")
          role = Role.find_or_create_by!(key:) { |row| row.name = role_label }
          link = OrganizationRole.create!(organization: org, role:, verification_status: "verified", verified_by: BY, verified_at: 30.days.ago)
          Evidence.create!(subject: link, source: site_source, quote: about, found_by: "human")
        end
        doc.css("a.nd-tag--link").first(3).each do |tag|
          label = tag.text.squish
          tech = Technology.find_or_create_by!(key: label.parameterize(separator: "_")) { |row| row.name = label }
          link = OrganizationTechnology.find_or_create_by!(organization: org, technology: tech) { |row| row.verification_status = "verified"; row.verified_by = BY; row.verified_at = 30.days.ago }
          Evidence.create!(subject: link, source: site_source, quote: about, found_by: "human")
        end
        rows.each do |left, type, right, quote, url, detail|
          other_name = left == name ? right : left
          other = Organization.find_by(name: other_name) || Organization.create!(name: other_name, verification_status: "verified", verified_by: BY, verified_at: 30.days.ago)
          from, to = left == name ? [ org, other ] : [ other, org ]
          deal = Relationship.create!(from_organization: from, to_organization: to, relationship_type: type, description: detail, verification_status: "verified", verified_by: BY, verified_at: 30.days.ago)
          Evidence.create!(subject: deal, source: Source.find_or_create_by!(url: url) { |row| row.source_kind = "web_page"; row.crawl_status = "ok" }, quote:, found_by: "human")
        end
        true
      end

      def get(url)
        cached = CACHE.join(Digest::SHA256.hexdigest(url)) if url.start_with?(SITE)
        return File.binread(cached).force_encoding("UTF-8") if cached&.exist? && cached.size.positive? && cached.mtime > 1.day.ago

        body =
          if cached # the directory's own public pages and index: a plain GET (its robots.txt keeps crawlers off /search)
            response = Net::HTTP.get_response(URI(url))
            response.body.to_s.dup.force_encoding("UTF-8") if response.is_a?(Net::HTTPSuccess)
          else
            response = @fetcher.get(url)
            response.body if response.kind == :ok && response.status == 200
          end
        if cached && body.present?
          FileUtils.mkdir_p(CACHE)
          File.binwrite(cached, body)
        end
        body
      end

      def company(page)
        slug = page[%r{/companies/([a-z0-9-]+)}, 1] or return
        Organization.find_by(slug:) || begin
          html = get(page).to_s
          name = html[/og:title" content="([^"]+)"/, 1] || slug.titleize
          # Its website as the public page shows it: a company's own site is a primary source (a press release on gle-us.com).
          site = Nokogiri::HTML(html).at_css("a[data-outbound='company_website']")&.[]("href").to_s.sub(/\?.*\z/, "").presence
          Organization.create!(name: CGI.unescapeHTML(name), slug:, website: site, verification_status: "verified", verified_by: BY, verified_at: 30.days.ago)
        end
      end

      def load_news(title, page, source, at)
        return true if NewsItem.exists?(url: source)

        org = company(page) or return
        html = get(source) or return
        date = page_date(html) or return
        news = NewsItem.create!(url: source, title: CGI.unescapeHTML(title), publisher: org.name, published_on: date,
          verification_status: "verified", verified_by: BY, verified_at: at)
        NewsMention.create!(news_item: news, subject: org)
      end

      def load_link(title, page, source, at, summary)
        verb = VERBS.keys.find { |word| title.include?(" #{word} ") }
        from_name, to_name = CGI.unescapeHTML(title).split(" #{verb} ", 2)
        from = company(page) or return
        to = Organization.find_by(name: to_name) || Organization.create!(name: to_name, verification_status: "verified", verified_by: BY, verified_at: 30.days.ago)
        return unless from.name == from_name

        text = ActionController::Base.helpers.strip_tags(get(source).to_s).squish
        first = ->(name) { name.split.first }
        quote = text.split(/(?<=[.!?])\s+/).find { |sentence| sentence.include?(first.(from.name)) && sentence.include?(first.(to.name)) } or return
        link = Relationship.create!(from_organization: from, to_organization: to, relationship_type: VERBS.fetch(verb), description: summary,
          verification_status: "verified", verified_by: BY, verified_at: at)
        VerificationEvent.where(subject: link).update_all(created_at: at)
        page_source = Source.find_or_create_by!(url: source) { |row| row.source_kind = "web_page"; row.crawl_status = "ok" }
        Evidence.create!(subject: link, source: page_source, quote:, found_by: "human")
      end

      # The page's own date: its datePublished/published_time, else the first "Month D, YYYY" or "D Month YYYY" in its text.
      def page_date(html)
        iso = html[/(?:datePublished|published_time|article:published)[^0-9]{0,40}(\d{4}-\d{2}-\d{2})/i, 1]
        return Date.iso8601(iso) if iso

        text = SocialAgent::Rules.article_text(html)
        months = Date::MONTHNAMES.compact.join("|")
        # The latest date the article gives, not in the future: a release's own date, not an event it mentions earlier.
        found = text.scan(/\b(?:#{months}) \d{1,2}, \d{4}\b|\b\d{1,2} (?:#{months}) \d{4}\b/).filter_map { |date| Date.parse(date) rescue nil }
        found.select { |date| date <= Date.current }.max
      rescue Date::Error
        nil
      end
  end
end
