# Company websites the nightly crawl couldn't read (#802 part 2): blocked,
# unreadable, empty, or so thin (a JavaScript-only page) that even its page
# data is under THIN_PAGE characters. Computed from the stored home pages;
# Backend shows the count and list on the admin and the DQ endpoint.
module DataQuality::BlankSites
  Site = Data.define(:company, :url, :reason, :checked_on)

  REASONS = {
    "blocked" => "Blocked us (robots.txt or 403)",
    "unreadable" => "Couldn't be read",
    "empty" => "Empty page",
    "js_only" => "Too little text (JavaScript-only page)"
  }.freeze

  BATCH = 25

  # Cached until a crawl fetches a page again, so a page load never re-parses
  # every home page; only BATCH page bodies are in memory at once (Infra).
  def self.list(directory: DataQuality::DirectoryClient.new)
    homes = directory.organizations_with_website.to_h { |name, website| [ Source.bare_homepage(website.to_s.strip), name ] }
    sources = Source.where(source_kind: "company_pages", url: homes.keys + homes.keys.map { |url| "#{url}/" })
    key = [ "blank_sites", Digest::SHA256.hexdigest(homes.to_a.sort.to_s), sources.maximum(:updated_at)&.to_i ]
    Rails.cache.fetch(key, expires_in: 1.day) { build(homes, sources) }
  end

  def self.build(homes, sources)
    reader = DataQuality::Plugins::CompanyPages.new
    site = ->(source, reason) { Site.new(company: homes[Source.bare_homepage(source.url)], url: source.url, reason: REASONS.fetch(reason), checked_on: source.fetched_at&.to_date) }
    failed = sources.where(crawl_status: %w[blocked needs_human]).select(:id, :url, :crawl_status, :fetched_at)
      .map { |source| site.(source, source.crawl_status == "blocked" ? "blocked" : "unreadable") }
    thin = []
    sources.where(crawl_status: "ok").find_each(batch_size: BATCH) do |source|
      reason = reason(source, reader)
      thin << site.(source, reason) if reason
    end
    (failed + thin).sort_by { |entry| entry.company.to_s.downcase }
  end

  def self.count(...) = list(...).size

  def self.reason(source, reader)
    return "empty" if source.content_text.blank?

    "js_only" if reader.send(:body_text, source).length < DataQuality::Plugin::THIN_PAGE
  end
end
