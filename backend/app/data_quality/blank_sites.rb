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

  def self.list(directory: DataQuality::DirectoryClient.new)
    homes = directory.organizations_with_website.to_h { |name, website| [ Source.bare_homepage(website.to_s.strip), name ] }
    reader = DataQuality::Plugins::CompanyPages.new
    sources = Source.where(source_kind: "company_pages", url: homes.keys + homes.keys.map { |url| "#{url}/" })
    sources.filter_map do |source|
      reason = reason(source, reader)
      next unless reason

      Site.new(company: homes[Source.bare_homepage(source.url)], url: source.url, reason: REASONS.fetch(reason), checked_on: source.fetched_at&.to_date)
    end.sort_by { |site| site.company.to_s.downcase }
  end

  def self.count(...) = list(...).size

  def self.reason(source, reader)
    return "blocked" if source.crawl_status == "blocked"
    return "unreadable" if source.crawl_status == "needs_human"
    return unless source.crawl_status == "ok"
    return "empty" if source.content_text.blank?

    "js_only" if reader.send(:body_text, source).length < DataQuality::Plugin::THIN_PAGE
  end
end
