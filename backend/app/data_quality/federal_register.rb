# Federal Register document pages send bots to a check page
# (unblock.federalregister.gov), so a document is read through the Federal
# Register's own API instead (#860): the same document, as JSON. Never a way
# around the page's check: the page itself isn't fetched.
module DataQuality::FederalRegister
  API = "https://www.federalregister.gov/api/v1/documents".freeze
  FIELDS = %w[document_number title publication_date abstract html_url agency_names].freeze
  HOST = /\A(?:www\.)?federalregister\.gov\z/i
  # /d/2026-12345 or /documents/2026/11/18/2026-12345/slug
  NUMBER = %r{\A/(?:d|documents/\d{4}/\d{2}/\d{2})/([A-Z0-9][A-Z0-9-]+?)(?:/|\z)}i

  # The document number in a Federal Register page's address, else nil.
  def self.document_number(url)
    uri = URI.parse(url.to_s.strip)
    uri.host.to_s.match?(HOST) ? uri.path.to_s[NUMBER, 1] : nil
  rescue URI::InvalidURIError
    nil
  end

  def self.api_url(number) = "#{API}/#{number}.json?#{URI.encode_www_form(FIELDS.map { |field| [ "fields[]", field ] })}"

  # The API's JSON as a small page: title, date (article meta) and abstract.
  def self.page(json)
    doc = JSON.parse(json.to_s) rescue {}
    title, date, abstract = ERB::Util.html_escape(doc["title"].to_s), ERB::Util.html_escape(doc["publication_date"].to_s), ERB::Util.html_escape(doc["abstract"].to_s)
    %(<html><head><title>#{title}</title><meta property="article:published_time" content="#{date}"><meta property="og:site_name" content="Federal Register"></head>) +
      %(<body><h1>#{title}</h1><p>#{abstract}</p></body></html>)
  end
end
