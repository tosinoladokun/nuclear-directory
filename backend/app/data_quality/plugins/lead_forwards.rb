# Forward to leads (#757; Tosin, 10 Nov): Tosin forwards any email (a
# LinkedIn suggestion, a newsletter, a news alert) to leads@ and its
# companies become leads in the one lead pipeline (#752). The newsletter
# reader's crawl, storage (visible text and cleaned links only) and model,
# with three differences:
# - only mail from LEAD_FORWARDERS (comma-separated, in the environment, never
#   in the repo) with DMARC pass is read; anything else is dropped unread;
# - any company the email names, not only US ones (the lead finder checks);
# - one short reply to the sender: "Added N leads: A, B. Already listed: C."
# A LinkedIn link is never opened: the lead finder takes its name only.
class DataQuality::Plugins::LeadForwards < DataQuality::Plugins::Newsletters
  INBOX = "leads@mail.nuclear-directory.org".freeze
  SEND_API = "https://api.resend.com/emails".freeze
  INSTRUCTIONS = <<~TEXT.freeze
    You read one email someone forwarded to suggest companies for a nuclear industry directory. List the companies it names
    that may work in the nuclear industry (reactors, fuel, enrichment, suppliers, utilities with nuclear plants, isotopes,
    nuclear engineering, nuclear investors). Not government agencies, national labs, universities, associations or people.
    For each: name exactly as written; quote, a sentence or phrase from the email naming it; website, only a link from the
    email that is plainly the company's own site (its home page), else null. Report nothing else.
  TEXT

  def initialize(forwarders: ENV["LEAD_FORWARDERS"], sender: nil, **options)
    super(**options)
    @forwarders = forwarders.to_s.split(",").map { |address| address.strip.downcase }.reject(&:blank?)
    @sender = sender
  end

  def crawl(run)
    return { "skipped" => "no LEAD_FORWARDERS" } if @forwarders.empty?

    super
  end

  def source_facts(_source)
    "This is one email forwarded to our leads@ address to suggest companies: a lead only, never cited for a fact."
  end

  private
    def inbox = INBOX
    def instructions = INSTRUCTIONS
    def lead_key = "forward"
    def lead_label = "Forwarded"

    # Only the allow-listed addresses themselves, never a display name or another sender.
    def sender?(from)
      @forwarders.include?(Mail::Address.new(from.to_s).address.to_s.downcase)
    rescue Mail::Field::ParseError
      false
    end

    # One reply per email, to the forwarder, sent once (the source remembers it in its etag).
    def after_leads(source, added, listed)
      return if source.etag == "replied"

      to = @forwarders.first or return
      lines = [ "Added #{added.size} #{'lead'.pluralize(added.size)}#{": #{added.join(', ')}" if added.any?}." ]
      lines << "Already listed: #{listed.join(', ')}." if listed.any?
      sent = (@sender || method(:send_reply)).call(to:, subject: "Re: #{source.title.to_s.split(': ', 2).last}", text: lines.join("\n"))
      source.update_columns(etag: "replied") if sent
    end

    def send_reply(to:, subject:, text:)
      uri = URI(SEND_API)
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |client|
        client.post(uri.path, { from: "Nuclear Directory <#{INBOX}>", to: [ to ], subject:, text: }.to_json,
          { "Authorization" => "Bearer #{@api_key}", "Content-Type" => "application/json", "User-Agent" => DataQuality::Fetcher::USER_AGENT })
      end
      response.is_a?(Net::HTTPSuccess)
    end
end
