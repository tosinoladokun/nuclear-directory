# Nuclear newsletters (#714; Tosin, 10 Nov): bot@mail.nuclear-directory.org
# is subscribed to nuclear-only newsletters, and this reads what they send
# us through Resend's receiving API (our own mail, so nothing is scraped).
#
# Crawl: new emails to bot@ from a SENDERS domain, whose DKIM passed, are
# each stored once as a source (the email's HTML), at most PER_RUN a night.
# Mail from anyone else is never read.
#
# Extract: the model names the US nuclear companies a story is about that the
# directory doesn't have. Each becomes a lead (the one lead pipeline, Tosin
# 10 Nov), with its own website when the email links one whose host isn't the
# newsletter's or a tracker's; the lead finder verifies and fills it. Never a
# claim: a newsletter is never evidence for a fact, and its private inbox URL
# is never cited.
class DataQuality::Plugins::Newsletters < DataQuality::Plugin
  API = "https://api.resend.com/emails/receiving".freeze
  INBOX = "bot@mail.nuclear-directory.org".freeze
  # Sender domains of the newsletters bot@ is subscribed to. Never Neutron Bytes: its robots.txt blocks AI crawlers, so its mail is never read either (PM, 10 Nov).
  SENDERS = %w[smartbrief.com ans.org nucnet.org neimagazine.com world-nuclear-news.org world-nuclear.org exchangemonitor.com].freeze
  class InboxError < StandardError; end
  PER_RUN = 20
  # Resend allows 2 requests a second: a pause between calls, one retry on 429.
  PAUSE = 0.6
  # The stored email at most (Infra: a 1 GB database).
  MAX_STORED = 100_000
  LINKS = "\n\nLinks in the email:\n".freeze
  # Emails opened a run, stored or not, and listing pages read.
  MAX_OPENED = 50
  MAX_PAGES = 5
  PROMPT_VERSION = "newsletters-1".freeze
  # Newsletter, mail and social hosts: never a company's own site.
  NOT_OWN = /(?:\A|\.)(?:smartbrief|ans|nucnet|neimagazine|world-nuclear-news|world-nuclear|neutronbytes|exchangemonitor|resend|mailchimp|list-manage|
    substack|hubspot|hs-sites|constantcontact|sendgrid|mailgun|linkedin|twitter|x|facebook|youtube|instagram|google|bit|ow|t)\.[a-z.]+\z/x
  INSTRUCTIONS = <<~TEXT.freeze
    You read one nuclear industry newsletter email. List the US companies whose own nuclear work a story reports: reactor
    developers, fuel and enrichment, suppliers, utilities running nuclear plants, isotope producers, engineering firms for
    nuclear projects, nuclear investors. Not government agencies, national labs, universities, associations or people.
    For each: name exactly as written; quote, a sentence or phrase from the email naming it and its nuclear work; website,
    only a link from the email that is plainly the company's own site (its home page), else null. Report nothing else.
  TEXT

  def initialize(fetcher: DataQuality::Fetcher.new, llm: nil, directory: DataQuality::DirectoryClient.new, http: nil, api_key: ENV["RESEND_API_KEY"],
    sleeper: ->(seconds) { sleep seconds })
    @fetcher, @llm, @directory, @http, @api_key, @sleeper = fetcher, llm, directory, http, api_key, sleeper
  end

  def crawl(_run)
    return { "skipped" => "no RESEND_API_KEY" } if @api_key.blank?

    fresh = listed_newsletters
    seen = Source.where(source_kind:, url: fresh.map { |mail| url_for(mail["id"]) }).pluck(:url)
    stored = opened = 0
    fresh.reject { |mail| seen.include?(url_for(mail["id"])) }.each do |mail|
      break if stored >= PER_RUN || opened >= MAX_OPENED

      opened += 1
      email = api_get("#{API}/#{mail['id']}") or raise InboxError, "Resend: couldn't read received email #{mail['id']}"
      # DMARC pass: the From domain itself is authenticated (aligned SPF or DKIM),
      # not just some domain's signature; bot@ is a public address (Infra).
      valid = email.dig("authentication", "dmarc") == "pass" && email["html"].present?
      # A rejected email is recorded too, so it never takes a later run's place.
      Source.create!(url: url_for(mail["id"]), source_kind:, crawl_status: valid ? "ok" : "needs_human", fetched_at: Time.current,
        http_status: 200, title: "#{sender_domain(mail['from'])}: #{email['subject'].to_s.gsub(EMAIL, '[email]').truncate(150)}",
        status_reason: (valid ? nil : "DMARC didn't pass, or no HTML"),
        **(valid ? stored(email["html"]) : {}))
      stored += 1 if valid
    end
    { "emails" => stored, "opened" => opened }
  end

  # Leads only, never claims: returns [] and notes each company as a lead.
  def extract(source, run)
    text = email_text(source)
    return [] if text.blank?

    urls = links(source)
    hosts = urls.index_by { |url| URI.parse(url).host.to_s.downcase.delete_prefix("www.") rescue nil }.except(nil)
    run&.update!(prompt_version: PROMPT_VERSION)
    # The model sees the email's links too, so it can pick a company's own site.
    input = "#{text.truncate(50_000)}\n\nLinks in the email:\n#{urls.uniq.first(300).join("\n")}"
    found = llm.structured(role: :extract, schema:, schema_name: "newsletters", crawl_run: run, reasoning_effort: "low",
      messages: [ { role: "system", content: INSTRUCTIONS }, { role: "user", content: input } ]).data
    id = source.url.split("/").last
    Array(found["companies"]).each do |company|
      name, quote = company["name"].to_s.squish, company["quote"].to_s.squish
      next if name.blank? || !quote.include?(name) || !text.include?(quote) || @directory.organization(name:)

      @directory.keep_lead(name:, key: "newsletter:#{id}:#{name.downcase.squish}",
        label: "Newsletter: #{source.title.to_s.truncate(120)}", url: own_site(company["website"], hosts))
    end
    []
  end

  def source_facts(_source)
    "This is one nuclear industry newsletter email received at our bot@ address: a lead to companies and their own " \
      "websites, never cited for a fact."
  end

  private
    def llm = @llm ||= DataQuality::OpenRouter::Client.new

    # What's kept of an email (DQ, 10 Nov: the repo is public): no images
    # (tracking pixels), no unsubscribe, preferences or "you're receiving
    # this" lines, no tracker links, no query strings, no email addresses.
    FOOTER = /unsubscribe|manage (?:your )?(?:preferences|subscription)|update (?:your )?(?:profile|preferences)|view (?:this email )?in (?:your |a )?browser|forward to a friend|you(?:'re| are) receiving this|this email was sent to|opt[ -]out/i
    TRACKER = /(?:\A|\.)(?:list-manage\.com|mailchimp\.com|mandrillapp\.com|hubspot(?:email)?\.(?:com|net)|hs-sites\.com|sendgrid\.net|constantcontact\.com|mcusercontent\.com|links\.smartbrief\.com|cmail\d*\.com|createsend\.com|exacttarget\.com|pardot\.com|marketo\.com|mktoweb\.com)\z|\A(?:click|clicks|trk|track|tracking|links?|email|e)\./i
    EMAIL = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/i
    def stored(html)
      doc = Nokogiri::HTML(html)
      doc.css("img, script, style, head").each(&:remove)
      doc.css("a").each do |link|
        next link.remove if link.text.match?(FOOTER) || link["href"].to_s.match?(/unsubscribe|optout|opt-out|preferences/i)

        uri = (URI.parse(link["href"].to_s.strip) rescue nil)
        if uri.is_a?(URI::HTTP) && uri.host.present? && !uri.host.match?(TRACKER)
          link["href"] = "#{uri.scheme}://#{uri.host}#{uri.path}"
        else
          link.remove_attribute("href")
        end
        link.attributes.each_key { |name| link.remove_attribute(name) unless name == "href" }
      end
      doc.css("p, td, div, span, li").select { |node| node.element_children.none? && node.text.match?(FOOTER) }.each(&:remove)
      doc.xpath("//text()").each { |node| node.content = node.content.gsub(EMAIL, "[email]") }
      # Only what's needed (Infra): the visible text, then the email's own links, one a line.
      visible = doc.xpath("//body//text()").map(&:text).join(" ").squish.byteslice(0, MAX_STORED).to_s.scrub("")
      urls = doc.css("a[href]").map { |link| link["href"] }.grep(%r{\Ahttps?://}i).uniq
      text = "#{visible}#{LINKS}#{urls.join("\n")}"
      { content_text: text, content_sha256: Digest::SHA256.hexdigest(text) }
    end

    def url_for(id) = "https://resend.com/emails/receiving/#{id}"

    # The From mailbox's own domain, never a display name's.
    def sender?(from)
      domain = Mail::Address.new(from.to_s).domain.to_s.downcase
      domain.present? && SENDERS.any? { |sender| domain == sender || domain.end_with?(".#{sender}") }
    rescue Mail::Field::ParseError
      false
    end

    # bot@'s newsletters across up to MAX_PAGES listing pages, newest first.
    # A failed listing with a key set fails the crawl (a sending-only key, say).
    def listed_newsletters
      mails, after = [], nil
      MAX_PAGES.times do
        page = api_get("#{API}?limit=100#{"&after=#{after}" if after}") or raise InboxError, "Resend: couldn't list received emails"
        data = Array(page["data"])
        mails.concat(data.select { |mail| Array(mail["to"]).map(&:downcase).include?(INBOX) && sender?(mail["from"]) })
        break unless page["has_more"] && data.any?

        after = data.last["id"]
      end
      mails
    end

    def links(source) = source.content_text.to_s.split(LINKS, 2).last.to_s.lines.map(&:strip).grep(%r{\Ahttps?://}i)

    # The email's text, without its links list.
    def email_text(source) = source.content_text.to_s.split(LINKS, 2).first.to_s.squish

    def sender_domain(from)
      Mail::Address.new(from.to_s).domain.to_s.downcase
    rescue Mail::Field::ParseError
      ""
    end

    # The model's website, only when the email links that host and it isn't a newsletter's or tracker's.
    def own_site(website, hosts)
      host = (URI.parse(website.to_s.strip).host.to_s.downcase.delete_prefix("www.") rescue "")
      return if host.blank? || host.match?(NOT_OWN) || !hosts.key?(host)

      "https://#{URI.parse(hosts[host]).host.downcase}"
    end

    def api_get(url)
      headers = { "Authorization" => "Bearer #{@api_key}", "Accept" => "application/json", "User-Agent" => DataQuality::Fetcher::USER_AGENT }
      2.times do |attempt|
        @sleeper.call(PAUSE) if @called
        @called = true
        status, body, retry_after = http.call(url, headers)
        if status == 429 && attempt.zero?
          @sleeper.call(retry_after.to_f.clamp(1.0, 10.0))
          next
        end
        return (JSON.parse(body) if status == 200 && body)
      end
      nil
    rescue JSON::ParserError
      nil
    end

    def http
      @http ||= lambda do |url, headers|
        uri = URI(url)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |client|
          client.get(uri.request_uri, headers)
        end
        [ response.code.to_i, response.body, response["Retry-After"] ]
      end
    end

    def schema
      { type: "object", additionalProperties: false, required: [ "companies" ], properties: { "companies" => { type: "array", items: {
        type: "object", additionalProperties: false, required: %w[name quote website],
        properties: { "name" => { type: "string" }, "quote" => { type: "string" }, "website" => { type: [ "string", "null" ] } } } } } }
    end
end
