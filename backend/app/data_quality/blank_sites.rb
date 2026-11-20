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
  # Cached until a crawl fetches a page again, so a page load never re-parses
  # every home page; only BATCH page bodies are in memory at once (Infra).
  def self.list(directory: DataQuality::DirectoryClient.new)
    homes = directory.organizations_with_website.group_by { |_, website| Source.bare_homepage(website.to_s.strip) }
      .transform_values { |rows| rows.map(&:first) }
    # A bare host is stored with or without its slash; a path only as given.
    urls = homes.keys.flat_map { |url| url.match?(%r{\Ahttps?://[^/?#\s]+\z}i) ? [ url, "#{url}/" ] : [ url ] }
    sources = Source.where(url: urls)
    key = [ "blank_sites", Digest::SHA256.hexdigest(homes.sort.to_s), sources.maximum(:updated_at)&.to_i ]
    Rails.cache.fetch(key, expires_in: 1.day) { build(homes, sources) }
  end

  def self.build(homes, sources)
    reader = DataQuality::Plugins::CompanyPages.new
    sites = ->(source, reason) do
      Array(homes[Source.bare_homepage(source.url)]).map do |company|
        Site.new(company:, url: source.url, reason: REASONS.fetch(reason), checked_on: source.fetched_at&.to_date)
      end
    end
    failed = sources.where.not(crawl_status: "ok").or(sources.where.not(status_reason: nil))
      .select(:id, :url, :crawl_status, :status_reason, :blocked_streak, :fetched_at)
      .flat_map { |source| (reason = failure(source)) ? sites.(source, reason) : [] }
    thin = []
    sources.where(crawl_status: "ok", status_reason: nil).find_each(batch_size: BATCH) do |source|
      reason = reason(source, reader)
      thin.concat(sites.(source, reason)) if reason
    end
    (failed + thin).sort_by { |entry| entry.company.to_s.downcase }
  end

  # The last fetch's outcome, as Snapshot records it: a block (or repeated
  # blocks, or robots.txt) is "blocked"; any other failed fetch, including a
  # timeout after an earlier good read, is "unreadable".
  def self.failure(source)
    return if source.fetched_at.nil?
    return "blocked" if source.crawl_status == "blocked" || source.blocked_streak.positive? || source.status_reason.to_s.match?(/robots|disallow/i)

    "unreadable" if source.crawl_status == "needs_human" || source.status_reason.present?
  end

  def self.count(...) = list(...).size

  def self.reason(source, reader)
    return "empty" if source.content_text.blank?

    "js_only" if reader.send(:visible_text, source).length < DataQuality::Plugin::THIN_PAGE
  end
end
