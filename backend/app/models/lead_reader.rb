# Reads what Tosin types in "Add a lead" (PM, 18 Nov): free text, one line or many ("Aalo, the Austin microreactor
# startup", "aalo.com", "that fusion company from the ANS article, Cameco"), into the companies it names, each with
# its website when the text gives one and a short hint for the finder. The cheap model reads it; if that fails, each
# line is read by hand (a link is the site, the rest the name).
#
#   LeadReader.new.call("Aalo, the Austin microreactor startup") # => [Item(name: "Aalo", website: nil, hint: "Austin microreactor startup")]
class LeadReader
  Item = Data.define(:name, :website, :hint)
  MAX_ITEMS = 50
  SCHEMA = { type: "object", additionalProperties: false, required: %w[companies], properties: {
    companies: { type: "array", maxItems: MAX_ITEMS, items: { type: "object", additionalProperties: false, required: %w[name website hint],
      properties: { name: { type: "string" }, website: { type: [ "string", "null" ] }, hint: { type: [ "string", "null" ] } } } }
  } }.freeze
  INSTRUCTIONS = <<~TEXT.freeze
    The user lists companies to add to a directory of the US nuclear industry, in any words. Return each company once:
    - name: the company's name as written (keep its spelling and capitals), or the website's name if only a site is given.
    - website: a URL or domain the user wrote for it (as https://...), else null. Never guess one.
    - hint: what else the user says about it (place, technology, where they saw it), in a few words, else null.
    Skip words that name no company.
  TEXT

  # Tests set their own model client; nil uses OpenRouter.
  class_attribute :default_client, default: nil

  # It runs inside the admin's request (one of Puma's three threads): one short try, then the hand reading (Infra).
  def self.quick_config
    env = DataQuality::Config.from_env
    DataQuality::Config.new(api_key: env.api_key, extract_model: env.extract_model, verify_model: env.verify_model,
      monthly_budget: env.monthly_budget, open_timeout: 5, read_timeout: 15, max_attempts: 1)
  end

  def initialize(client: nil)
    @client = client || default_client
  end

  def call(text)
    read_with_model(text) || read_by_hand(text)
  end

  # Each line by hand: a link anywhere is the site, the words around it the name.
  def read_by_hand(text)
    text.to_s.lines.map(&:squish).compact_blank.uniq.first(MAX_ITEMS).filter_map do |line|
      url = line[%r{https?://\S+}i]
      name = url ? line.sub(url, "").squish.gsub(/\A[\s:,–—-]+|[\s:,–—-]+\z/, "").squish.presence : line
      name ||= CompanySuggestion.link_name(url)
      Item.new(name:, website: url, hint: nil) if name.present?
    end
  end

  private
    def read_with_model(text)
      run = CrawlRun.create!(source_kind: "add_a_lead", stage: "extract", started_at: Time.current)
      client = @client || DataQuality::OpenRouter::Client.new(config: self.class.quick_config)
      data = client.structured(role: :extract, schema: SCHEMA, schema_name: "leads", crawl_run: run, messages: [
        { role: "system", content: INSTRUCTIONS }, { role: "user", content: text.to_s.truncate(5_000) }
      ]).data
      run.finish!
      typed = text.to_s.downcase
      items = Array(data["companies"]).filter_map do |company|
        name = company["name"].to_s.squish.first(CompanySuggestion::MAX)
        next if name.blank?
        # Never a company he didn't name (DQ): its name, or its first word, or its site must be in what he typed.
        next unless typed?(typed, name, company["website"])

        Item.new(name:, website: website(company["website"]), hint: company["hint"].to_s.squish.first(300).presence)
      end
      items.uniq(&:name).first(MAX_ITEMS).presence
    rescue DataQuality::OpenRouter::Client::Error, DataQuality::Config::ConfigurationError, DataQuality::Budget::Exceeded => error
      run&.fail!(error.message)
      nil
    end

    def typed?(typed, name, site)
      first = name.split.first.to_s.downcase
      host = (URI.parse(website(site).to_s).host.to_s.downcase.delete_prefix("www.") rescue "")
      typed.include?(name.downcase) || (first.length >= 3 && typed.match?(/\b#{Regexp.escape(first)}\b/)) ||
        (host.present? && typed.include?(host))
    end

    # Only a plain https site: a bare domain gets https://; anything else is dropped.
    def website(value)
      value = value.to_s.strip
      return if value.blank?

      value = "https://#{value}" unless value.match?(%r{\Ahttps?://}i)
      uri = URI.parse(value)
      uri.host.to_s.include?(".") ? "https://#{uri.host}#{uri.path}" : nil
    rescue URI::InvalidURIError
      nil
    end
end
