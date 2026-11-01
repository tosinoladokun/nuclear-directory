# One entry per approved fact: its sentence, the page it's on, its source.
page_url = ->(entry) { entry.page.first == :company ? company_url(slug: entry.page.last) : plant_url(slug: entry.page.last) }
xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
xml.feed xmlns: "http://www.w3.org/2005/Atom" do
  xml.id updates_feed_url
  xml.title "Nuclear Directory: what's new"
  xml.subtitle "Newly approved facts, deals and news, each with its source"
  xml.link rel: "self", type: "application/atom+xml", href: updates_feed_url
  xml.link rel: "alternate", type: "text/html", href: root_url
  xml.updated((@entries.first&.at || Time.current).utc.iso8601)
  xml.author { xml.name "Nuclear Directory" }
  @entries.each do |entry|
    xml.entry do
      xml.id "tag:#{request.host},2026:#{entry.key}"
      xml.title entry.title
      xml.link rel: "alternate", type: "text/html", href: page_url.call(entry)
      xml.link rel: "related", href: entry.source_url if entry.source_url
      xml.updated entry.at.utc.iso8601
      xml.category term: entry.kind
      xml.summary [ entry.summary, ("Source: #{entry.source_url}" if entry.source_url) ].compact.join(" ")
    end
  end
end
